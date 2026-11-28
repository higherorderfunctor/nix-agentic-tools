//! A bounded recent-attempt view. Inspect bytes while the client consumes them.
use std::{
    collections::VecDeque,
    pin::Pin,
    sync::{Arc, Mutex},
    task::{Context, Poll},
};

use hyper::{
    body::{Body, Bytes, Frame, Incoming},
    header::{CONTENT_ENCODING, CONTENT_TYPE, HeaderMap},
};
use serde::Serialize;
use serde_json::Value;

#[derive(Default)]
pub(super) struct Ledger(Arc<Mutex<VecDeque<Record>>>);

#[derive(Serialize)]
struct Record {
    client: String,
    model: String,
    pool: String,
    status: Option<u16>,
    completed: bool,
    input_tokens: Option<u64>,
    output_tokens: Option<u64>,
}

pub(super) struct Attempt {
    ledger: Arc<Mutex<VecDeque<Record>>>,
    client: String,
    model: String,
    pool: String,
    pub status: Option<u16>,
    completed: bool,
    input_tokens: Option<u64>,
    output_tokens: Option<u64>,
}

const MAX_RECORDS: usize = 128;
const MAX_USAGE_BYTES: usize = 16 * 1024;

impl Ledger {
    pub fn attempt(&self, client: &str, model: &str, pool: &str) -> Attempt {
        Attempt {
            ledger: Arc::clone(&self.0),
            client: client.into(),
            model: model.into(),
            pool: pool.into(),
            status: None,
            completed: false,
            input_tokens: None,
            output_tokens: None,
        }
    }

    pub fn json(&self) -> Bytes {
        Bytes::from(serde_json::to_vec(&*self.0.lock().unwrap()).expect("serialize usage records"))
    }
}

impl Attempt {
    pub fn complete_json(mut self, bytes: &[u8]) {
        self.usage(bytes);
        self.completed = true;
    }
    pub fn observe(self, headers: &HeaderMap, body: Incoming) -> ObservedBody {
        let content_type = headers
            .get(CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .unwrap_or_default()
            .split(';')
            .next()
            .unwrap_or_default();
        let encoding = headers
            .get(CONTENT_ENCODING)
            .and_then(|value| value.to_str().ok())
            .unwrap_or("identity");
        let format = match (content_type, encoding) {
            ("text/event-stream", "identity") => Format::Sse,
            ("application/json", "identity") => Format::Json,
            _ => Format::Opaque,
        };
        let mut observed = ObservedBody {
            attempt: Some(self),
            body,
            format,
            pending: Vec::new(),
            overflow: false,
        };
        if observed.body.is_end_stream() {
            observed.finish();
        }
        observed
    }

    fn usage(&mut self, bytes: &[u8]) {
        let Ok(event) = serde_json::from_slice::<Value>(bytes) else {
            return;
        };
        let usage = event
            .get("usage")
            .or_else(|| event.pointer("/message/usage"));
        let Some(usage) = usage else {
            return;
        };
        if let Some(input) = usage.get("input_tokens").and_then(Value::as_u64) {
            self.input_tokens = Some(input);
        }
        if let Some(output) = usage.get("output_tokens").and_then(Value::as_u64) {
            self.output_tokens = Some(output);
        }
    }
}

impl Drop for Attempt {
    fn drop(&mut self) {
        let mut records = self.ledger.lock().unwrap();
        if records.len() >= MAX_RECORDS {
            records.pop_front();
        }
        records.push_back(Record {
            client: std::mem::take(&mut self.client),
            model: std::mem::take(&mut self.model),
            pool: std::mem::take(&mut self.pool),
            status: self.status,
            completed: self.completed,
            input_tokens: self.input_tokens,
            output_tokens: self.output_tokens,
        });
    }
}

#[derive(Clone, Copy)]
enum Format {
    Sse,
    Json,
    Opaque,
}

pub(super) struct ObservedBody {
    attempt: Option<Attempt>,
    body: Incoming,
    format: Format,
    pending: Vec<u8>,
    overflow: bool,
}

impl ObservedBody {
    fn bytes(&mut self, bytes: &[u8]) {
        match self.format {
            Format::Opaque => {}
            Format::Json => self.append(bytes),
            Format::Sse => {
                for part in bytes.split_inclusive(|byte| *byte == b'\n') {
                    self.append(part);
                    if part.ends_with(b"\n") {
                        self.event();
                    }
                }
            }
        }
    }

    fn append(&mut self, bytes: &[u8]) {
        if self.pending.len() + bytes.len() > MAX_USAGE_BYTES {
            self.overflow = true;
        }
        if !self.overflow {
            self.pending.extend_from_slice(bytes);
        }
    }

    fn event(&mut self) {
        if !self.overflow
            && let Some(data) = self.pending.strip_prefix(b"data:")
            && let Some(attempt) = &mut self.attempt
        {
            attempt.usage(data);
        }
        self.pending.clear();
        self.overflow = false;
    }

    fn finish(&mut self) {
        if matches!(self.format, Format::Sse) {
            self.event();
        }
        if let Some(mut attempt) = self.attempt.take() {
            if matches!(self.format, Format::Json) && !self.overflow {
                attempt.usage(&self.pending);
            }
            attempt.completed = true;
        }
    }
}

impl Body for ObservedBody {
    type Data = Bytes;
    type Error = hyper::Error;

    fn poll_frame(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, hyper::Error>>> {
        let result = Pin::new(&mut self.body).poll_frame(cx);
        match &result {
            Poll::Ready(Some(Ok(frame))) => {
                if let Some(data) = frame.data_ref() {
                    self.bytes(data);
                }
                if self.body.is_end_stream() {
                    self.finish();
                }
            }
            Poll::Ready(None) => self.finish(),
            Poll::Ready(Some(Err(_))) => {
                self.attempt.take();
            }
            Poll::Pending => {}
        }
        result
    }
}
