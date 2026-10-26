//! Bounded observation of Anthropic request usage without changing response bytes.

use std::{
    io::Read,
    pin::Pin,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::{Instant, SystemTime, UNIX_EPOCH},
};

use airlock_core::{
    ids::{ClientId, CredentialId, GroupId},
    storage::{RequestEvent, RequestOutcome, Storage, StorageError},
};
use flate2::{Decompress, FlushDecompress, Status, read::MultiGzDecoder};
use serde::Deserialize;
use tokio::sync::mpsc;
use zeroize::Zeroizing;

const MAX_OBSERVED_BYTES: usize = 1 << 20;
const TELEMETRY_QUEUE_CAPACITY: usize = 32;

pub(crate) struct RequestUsageIdentity {
    pub client: ClientId,
    pub credential: CredentialId,
    pub group: GroupId,
    pub model: String,
}

/// A storage implementation used by the gateway's bounded telemetry dispatcher.
pub trait RequestUsageSink: Send + Sync + 'static {
    fn append_request_event<'a>(
        &'a self,
        event: RequestEvent,
    ) -> Pin<Box<dyn std::future::Future<Output = Result<(), StorageError>> + Send + 'a>>;
}

impl<T> RequestUsageSink for T
where
    T: Storage + Send + Sync + 'static,
{
    fn append_request_event<'a>(
        &'a self,
        event: RequestEvent,
    ) -> Pin<Box<dyn std::future::Future<Output = Result<(), StorageError>> + Send + 'a>> {
        Box::pin(async move { self.try_append_request_event(event).await })
    }
}

#[derive(Clone, Default)]
pub(crate) struct UsageTelemetry {
    dropped: Arc<AtomicU64>,
    sender: Option<mpsc::Sender<RequestEvent>>,
}

impl UsageTelemetry {
    pub(crate) fn disabled() -> Self {
        Self::default()
    }

    pub(crate) fn new(sink: Arc<dyn RequestUsageSink>) -> (Self, tokio::task::JoinHandle<()>) {
        let (sender, mut receiver) = mpsc::channel::<RequestEvent>(TELEMETRY_QUEUE_CAPACITY);
        let dropped = Arc::new(AtomicU64::new(0));
        let worker_dropped = Arc::clone(&dropped);
        let worker = tokio::spawn(async move {
            while let Some(mut event) = receiver.recv().await {
                event.dropped_events = worker_dropped.swap(0, Ordering::AcqRel);
                if sink.append_request_event(event.clone()).await.is_err() {
                    worker_dropped
                        .fetch_add(event.dropped_events.saturating_add(1), Ordering::AcqRel);
                    tracing::warn!(
                        target: "airlock::usage",
                        reason = "storage_failed",
                        "request usage telemetry dropped"
                    );
                }
            }
        });
        (
            Self {
                dropped,
                sender: Some(sender),
            },
            worker,
        )
    }

    pub(crate) fn request(
        &self,
        identity: RequestUsageIdentity,
        request_bytes: u64,
        status_code: u16,
        started: Instant,
    ) -> RequestUsageTracker {
        RequestUsageTracker {
            client: identity.client,
            complete: true,
            credential: identity.credential,
            dropped: Arc::clone(&self.dropped),
            finished: false,
            group: identity.group,
            latency_started: started,
            model: identity.model,
            occurred_at_unix: current_unix(),
            dimensions: UsageDimensions::default(),
            observer: None,
            request_bytes,
            response_bytes: 0,
            sender: self.sender.clone(),
            status_code,
        }
    }
}

enum BodyFormat {
    Json,
    Sse,
}

enum UsageObserver {
    CompressedJson {
        compressed: Zeroizing<Vec<u8>>,
    },
    Json(Zeroizing<Vec<u8>>),
    Sse {
        buffer: Zeroizing<Vec<u8>>,
        dimensions: UsageDimensions,
        gzip: Option<Box<GzipState>>,
        terminal: bool,
    },
}

struct GzipState {
    decoder: Decompress,
    finished: bool,
}

impl GzipState {
    fn new() -> Self {
        Self {
            decoder: Decompress::new_gzip(15),
            finished: false,
        }
    }

    fn observe(
        &mut self,
        input: &[u8],
        buffer: &mut Zeroizing<Vec<u8>>,
        dimensions: &mut UsageDimensions,
        terminal: &mut bool,
    ) -> bool {
        if self.finished {
            return input.is_empty();
        }
        let mut remaining = input;
        let mut produced_total = 0_usize;
        loop {
            let mut output = Zeroizing::new([0_u8; 16 * 1024]);
            let before_in = self.decoder.total_in();
            let before_out = self.decoder.total_out();
            let Ok(status) =
                self.decoder
                    .decompress(remaining, &mut *output, FlushDecompress::None)
            else {
                return false;
            };
            let Ok(consumed) = usize::try_from(self.decoder.total_in() - before_in) else {
                return false;
            };
            let Ok(produced) = usize::try_from(self.decoder.total_out() - before_out) else {
                return false;
            };
            if produced > MAX_OBSERVED_BYTES.saturating_sub(produced_total) {
                return false;
            }
            produced_total += produced;
            remaining = &remaining[consumed..];
            if !observe_sse_bytes(buffer, dimensions, terminal, &output[..produced]) {
                return false;
            }
            if status == Status::StreamEnd {
                self.finished = true;
                return remaining.is_empty();
            }
            if consumed == 0 && produced == 0 {
                return remaining.is_empty();
            }
            if remaining.is_empty() && produced < output.len() {
                return true;
            }
        }
    }
}

#[derive(Clone, Copy, Default)]
#[expect(
    clippy::struct_field_names,
    reason = "token units remain explicit in every observed dimension"
)]
struct UsageDimensions {
    cache_read_tokens: Option<u64>,
    cache_write_tokens: Option<u64>,
    input_tokens: Option<u64>,
    output_tokens: Option<u64>,
}

#[derive(Clone, Deserialize)]
#[expect(
    clippy::struct_field_names,
    reason = "fields mirror the Anthropic usage wire format"
)]
struct UsageFields {
    cache_creation_input_tokens: Option<u64>,
    cache_read_input_tokens: Option<u64>,
    input_tokens: Option<u64>,
    output_tokens: Option<u64>,
}

#[derive(Deserialize)]
struct UsageEvent<'a> {
    message: Option<MessageUsage>,
    r#type: Option<&'a str>,
    usage: Option<UsageFields>,
}

#[derive(Deserialize)]
struct MessageUsage {
    usage: Option<UsageFields>,
}

pub(crate) struct RequestUsageTracker {
    client: ClientId,
    complete: bool,
    credential: CredentialId,
    dropped: Arc<AtomicU64>,
    finished: bool,
    group: GroupId,
    latency_started: Instant,
    model: String,
    occurred_at_unix: i64,
    dimensions: UsageDimensions,
    observer: Option<UsageObserver>,
    request_bytes: u64,
    response_bytes: u64,
    sender: Option<mpsc::Sender<RequestEvent>>,
    status_code: u16,
}

impl RequestUsageTracker {
    pub(crate) fn set_status(&mut self, status_code: u16) {
        self.status_code = status_code;
    }

    pub(crate) fn observe_response(
        &mut self,
        content_type: Option<&[u8]>,
        content_encoding: Option<&[u8]>,
    ) {
        let format = if content_type.is_some_and(|value| {
            value
                .split(|byte| *byte == b';')
                .next()
                .is_some_and(|mime| mime.trim_ascii().eq_ignore_ascii_case(b"text/event-stream"))
        }) {
            BodyFormat::Sse
        } else {
            BodyFormat::Json
        };
        let observer = match content_encoding.map(<[u8]>::trim_ascii) {
            None | Some(b"identity") => match format {
                BodyFormat::Json => UsageObserver::Json(Zeroizing::new(Vec::new())),
                BodyFormat::Sse => UsageObserver::Sse {
                    buffer: Zeroizing::new(Vec::new()),
                    dimensions: UsageDimensions::default(),
                    gzip: None,
                    terminal: false,
                },
            },
            Some(value)
                if value.eq_ignore_ascii_case(b"gzip") || value.eq_ignore_ascii_case(b"x-gzip") =>
            {
                match format {
                    BodyFormat::Json => UsageObserver::CompressedJson {
                        compressed: Zeroizing::new(Vec::new()),
                    },
                    BodyFormat::Sse => UsageObserver::Sse {
                        buffer: Zeroizing::new(Vec::new()),
                        dimensions: UsageDimensions::default(),
                        gzip: Some(Box::new(GzipState::new())),
                        terminal: false,
                    },
                }
            }
            Some(_) => {
                self.complete = false;
                return;
            }
        };
        self.observer = Some(observer);
    }

    pub(crate) fn observe_chunk(&mut self, chunk: &[u8]) {
        self.response_bytes = self.response_bytes.saturating_add(chunk.len() as u64);
        if !self.complete {
            return;
        }
        let Some(observer) = &mut self.observer else {
            return;
        };
        match observer {
            UsageObserver::Json(bytes) => {
                if append_bounded(bytes, chunk).is_err() {
                    self.complete = false;
                }
            }
            UsageObserver::Sse {
                buffer,
                dimensions,
                gzip,
                terminal,
            } => {
                let valid = if let Some(decoder) = gzip {
                    decoder.observe(chunk, buffer, dimensions, terminal)
                } else {
                    observe_sse_bytes(buffer, dimensions, terminal, chunk)
                };
                self.complete &= valid;
            }
            UsageObserver::CompressedJson { compressed } => {
                if append_bounded(compressed, chunk).is_err() {
                    self.complete = false;
                }
            }
        }
    }

    pub(crate) fn observe_sse_event(&mut self, event: &[u8]) {
        self.response_bytes = self.response_bytes.saturating_add(event.len() as u64);
        let Some(UsageObserver::Sse {
            buffer,
            dimensions,
            terminal,
            ..
        }) = &mut self.observer
        else {
            self.complete = false;
            return;
        };
        self.complete &= observe_sse_bytes(buffer, dimensions, terminal, event);
    }

    pub(crate) fn observe_json(&mut self, bytes: &[u8]) {
        self.response_bytes = self.response_bytes.saturating_add(bytes.len() as u64);
        let Some(UsageObserver::Json(buffer)) = &mut self.observer else {
            self.complete = false;
            return;
        };
        if append_bounded(buffer, bytes).is_err() {
            self.complete = false;
        }
    }

    pub(crate) fn finish(&mut self, outcome: RequestOutcome) {
        if self.finished {
            return;
        }
        self.finished = true;
        if let Some(observer) = self.observer.take() {
            self.finish_observer(observer);
        } else {
            self.complete = false;
        }
        self.send(outcome);
    }

    pub(crate) fn finish_without_observation(&mut self, outcome: RequestOutcome) {
        if self.finished {
            return;
        }
        self.finished = true;
        self.complete = false;
        self.send(outcome);
    }

    fn finish_observer(&mut self, observer: UsageObserver) {
        match observer {
            UsageObserver::Json(bytes) => self.parse_json(&bytes),
            UsageObserver::Sse {
                buffer,
                dimensions,
                gzip,
                terminal,
            } => {
                if !buffer.is_empty()
                    || !terminal
                    || gzip.as_ref().is_some_and(|state| !state.finished)
                {
                    self.complete = false;
                }
                self.set_dimensions(dimensions);
            }
            UsageObserver::CompressedJson { compressed } => {
                let Some(plaintext) = decompress_bounded(&compressed) else {
                    self.complete = false;
                    return;
                };
                self.parse_json(&plaintext);
            }
        }
    }

    fn parse_json(&mut self, bytes: &[u8]) {
        match serde_json::from_slice::<UsageEvent>(bytes) {
            Ok(event) => {
                if let Some(fields) = event_usage(&event) {
                    self.set_dimensions(UsageDimensions {
                        cache_read_tokens: fields.cache_read_input_tokens,
                        cache_write_tokens: fields.cache_creation_input_tokens,
                        input_tokens: fields.input_tokens,
                        output_tokens: fields.output_tokens,
                    });
                } else {
                    self.complete = false;
                }
            }
            Err(_) => self.complete = false,
        }
    }

    fn set_dimensions(&mut self, dimensions: UsageDimensions) {
        self.dimensions = dimensions;
    }

    fn send(&mut self, outcome: RequestOutcome) {
        let Some(sender) = &self.sender else {
            return;
        };
        let dimensions = self.dimensions;
        let event = RequestEvent {
            dropped_events: 0,
            cache_read_tokens: dimensions.cache_read_tokens,
            cache_write_tokens: dimensions.cache_write_tokens,
            client: self.client.clone(),
            credential: self.credential.clone(),
            group: self.group.clone(),
            input_tokens: dimensions.input_tokens,
            latency_ms: u64::try_from(self.latency_started.elapsed().as_millis())
                .unwrap_or(u64::MAX),
            model: self.model.clone(),
            occurred_at_unix: self.occurred_at_unix,
            outcome,
            output_tokens: dimensions.output_tokens,
            request_bytes: self.request_bytes,
            response_bytes: self.response_bytes,
            status_code: self.status_code,
            usage_complete: self.complete,
        };
        match sender.try_send(event) {
            Ok(()) => {}
            Err(mpsc::error::TrySendError::Full(_)) => {
                self.dropped.fetch_add(1, Ordering::AcqRel);
                tracing::warn!(target: "airlock::usage", reason = "queue_full", "request usage telemetry dropped");
            }
            Err(mpsc::error::TrySendError::Closed(_)) => {
                self.dropped.fetch_add(1, Ordering::AcqRel);
                tracing::warn!(target: "airlock::usage", reason = "worker_closed", "request usage telemetry dropped");
            }
        }
    }
}

impl Drop for RequestUsageTracker {
    fn drop(&mut self) {
        self.finish(RequestOutcome::Cancelled);
    }
}

impl UsageDimensions {
    fn apply_cumulative(&mut self, fields: &UsageFields) {
        if let Some(value) = fields.cache_read_input_tokens {
            self.cache_read_tokens = Some(value);
        }
        if let Some(value) = fields.cache_creation_input_tokens {
            self.cache_write_tokens = Some(value);
        }
        if let Some(value) = fields.input_tokens {
            self.input_tokens = Some(value);
        }
        if let Some(value) = fields.output_tokens {
            self.output_tokens = Some(value);
        }
    }
}

impl MessageUsage {
    fn usage(&self) -> Option<UsageFields> {
        self.usage.clone()
    }
}

impl UsageEvent<'_> {
    fn usage(&self) -> Option<UsageFields> {
        self.usage.clone()
    }
}

fn event_usage(event: &UsageEvent) -> Option<UsageFields> {
    if event.r#type == Some("message_start") {
        return event.message.as_ref()?.usage();
    }
    event.usage()
}

fn observe_sse_bytes(
    buffer: &mut Zeroizing<Vec<u8>>,
    dimensions: &mut UsageDimensions,
    terminal: &mut bool,
    chunk: &[u8],
) -> bool {
    if chunk.len() > MAX_OBSERVED_BYTES {
        return false;
    }
    let mut remaining = chunk;
    while !remaining.is_empty() {
        let room = MAX_OBSERVED_BYTES.saturating_sub(buffer.len());
        if room == 0 {
            return false;
        }
        let taken = room.min(remaining.len());
        buffer.extend_from_slice(&remaining[..taken]);
        remaining = &remaining[taken..];
        while let Some(end) = sse_event_end(buffer) {
            let event = Zeroizing::new(buffer[..end].to_vec());
            buffer.drain(..end);
            if !observe_sse_event(&event, dimensions, terminal) {
                return false;
            }
        }
    }
    true
}

fn observe_sse_event(event: &[u8], dimensions: &mut UsageDimensions, terminal: &mut bool) -> bool {
    let Some(data) = sse_data(event) else {
        return !has_sse_data(event);
    };
    if data.as_slice() == b"[DONE]" {
        *terminal = true;
        return true;
    }
    let Ok(parsed) = serde_json::from_slice::<UsageEvent>(&data) else {
        return false;
    };
    match parsed.r#type {
        Some("message_start" | "message_delta") => {
            let Some(fields) = event_usage(&parsed) else {
                return false;
            };
            dimensions.apply_cumulative(&fields);
        }
        Some("message_stop") => *terminal = true,
        Some(_) => {}
        None => return false,
    }
    true
}

fn sse_data(event: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
    let mut data = Zeroizing::new(Vec::new());
    for line in event.split_inclusive(|byte| *byte == b'\n' || *byte == b'\r') {
        let mut line = line;
        while matches!(line.last(), Some(b'\n' | b'\r')) {
            line = &line[..line.len() - 1];
        }
        let Some(value) = line.strip_prefix(b"data:") else {
            continue;
        };
        let value = value.strip_prefix(b" ").unwrap_or(value);
        if !data.is_empty() {
            data.push(b'\n');
        }
        if append_bounded(&mut data, value).is_err() {
            return None;
        }
    }
    (!data.is_empty()).then_some(data)
}

fn has_sse_data(event: &[u8]) -> bool {
    event
        .split_inclusive(|byte| *byte == b'\n' || *byte == b'\r')
        .any(|line| line.trim_ascii_end().starts_with(b"data:"))
}

fn append_bounded(destination: &mut Zeroizing<Vec<u8>>, chunk: &[u8]) -> Result<(), ()> {
    if chunk.len() > MAX_OBSERVED_BYTES.saturating_sub(destination.len()) {
        return Err(());
    }
    destination.extend_from_slice(chunk);
    Ok(())
}

fn decompress_bounded(compressed: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
    let decoder = MultiGzDecoder::new(compressed);
    let mut plaintext = Zeroizing::new(Vec::new());
    decoder
        .take((MAX_OBSERVED_BYTES + 1) as u64)
        .read_to_end(&mut plaintext)
        .ok()?;
    (plaintext.len() <= MAX_OBSERVED_BYTES).then_some(plaintext)
}

fn current_unix() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(1, |seconds| {
            i64::try_from(seconds.as_secs()).unwrap_or(i64::MAX)
        })
}

pub(crate) fn sse_event_end(bytes: &[u8]) -> Option<usize> {
    let mut line_start = 0;
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'\r' || bytes[index] == b'\n' {
            let blank = index == line_start;
            let cr = bytes[index] == b'\r';
            index += 1;
            if cr && bytes.get(index) == Some(&b'\n') {
                index += 1;
            }
            if blank {
                return Some(index);
            }
            line_start = index;
        } else {
            index += 1;
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use std::{
        io::Write,
        sync::{
            Arc, Mutex,
            atomic::{AtomicUsize, Ordering},
        },
    };

    use flate2::{Compression, write::GzEncoder};

    use super::*;

    #[derive(Default)]
    struct Sink {
        events: Mutex<Vec<RequestEvent>>,
        failures: AtomicUsize,
    }

    struct SlowSink {
        events: Mutex<Vec<RequestEvent>>,
        entered: tokio::sync::Semaphore,
        release: tokio::sync::Semaphore,
    }

    impl RequestUsageSink for SlowSink {
        fn append_request_event<'a>(
            &'a self,
            event: RequestEvent,
        ) -> Pin<Box<dyn std::future::Future<Output = Result<(), StorageError>> + Send + 'a>>
        {
            Box::pin(async move {
                if self.events.lock().expect("events lock").is_empty() {
                    self.entered.add_permits(1);
                    let permit = self.release.acquire().await.expect("release gate");
                    permit.forget();
                }
                self.events.lock().expect("events lock").push(event);
                Ok(())
            })
        }
    }

    impl RequestUsageSink for Sink {
        fn append_request_event<'a>(
            &'a self,
            event: RequestEvent,
        ) -> Pin<Box<dyn std::future::Future<Output = Result<(), StorageError>> + Send + 'a>>
        {
            Box::pin(async move {
                if self
                    .failures
                    .try_update(Ordering::AcqRel, Ordering::Acquire, |n| n.checked_sub(1))
                    .is_ok()
                {
                    return Err(StorageError::UsageUnavailable);
                }
                self.events.lock().expect("events lock").push(event);
                Ok(())
            })
        }
    }

    fn tracker(telemetry: &UsageTelemetry) -> RequestUsageTracker {
        telemetry.request(
            RequestUsageIdentity {
                client: ClientId::try_from("harness").expect("client"),
                credential: CredentialId::try_from("zai").expect("credential"),
                group: GroupId::try_from("anthropic").expect("group"),
                model: "glm-4.7".to_owned(),
            },
            23,
            200,
            Instant::now(),
        )
    }

    async fn drain(telemetry: UsageTelemetry, worker: tokio::task::JoinHandle<()>) {
        drop(telemetry);
        worker.await.expect("worker joins");
    }

    #[tokio::test]
    async fn split_and_coalesced_sse_uses_cumulative_usage() {
        let sink = Arc::new(Sink::default());
        let (telemetry, worker) = UsageTelemetry::new(sink.clone());
        let mut request = tracker(&telemetry);
        request.observe_response(Some(b"text/event-stream; charset=utf-8"), None);
        let stream = concat!(
            "event: message_start\r\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":11,\"cache_read_input_tokens\":5,\"cache_creation_input_tokens\":3,\"output_tokens\":1}}}\r\n\r\n",
            "data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"fake-SECRET-prompt\"}}\n\n",
            "data: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":3}}\n\n",
            "data: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":7}}\n\n",
            "data: {\"type\":\"message_stop\"}\n\n",
        );
        for part in stream.as_bytes().chunks(7) {
            request.observe_chunk(part);
        }
        request.finish(RequestOutcome::Completed);
        drop(request);
        drain(telemetry, worker).await;
        let events = sink.events.lock().expect("events lock");
        assert_eq!(events.len(), 1);
        let event = &events[0];
        assert_eq!(event.input_tokens, Some(11));
        assert_eq!(event.output_tokens, Some(7));
        assert_eq!(event.cache_read_tokens, Some(5));
        assert_eq!(event.cache_write_tokens, Some(3));
        assert_eq!(event.response_bytes, stream.len() as u64);
        assert!(event.usage_complete);
    }

    #[tokio::test]
    async fn compressed_sse_observes_incrementally_beyond_one_megabyte() {
        const PADDING: &[u8] = b": padding\n\n";
        const USAGE: &[u8] = b"data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":4}}}\n\ndata: {\"type\":\"message_stop\"}\n\n";
        let sink = Arc::new(Sink::default());
        let (telemetry, worker) = UsageTelemetry::new(sink.clone());
        let mut request = tracker(&telemetry);
        request.observe_response(Some(b"text/event-stream"), Some(b"gzip"));
        let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
        for _ in 0..100_000 {
            encoder.write_all(PADDING).expect("gzip write");
        }
        encoder.write_all(USAGE).expect("gzip usage");
        assert!(100_000 * PADDING.len() + USAGE.len() > MAX_OBSERVED_BYTES);
        let compressed = encoder.finish().expect("gzip finish");
        for part in compressed.chunks(3) {
            request.observe_chunk(part);
        }
        request.finish(RequestOutcome::Completed);
        drop(request);
        drain(telemetry, worker).await;
        let events = sink.events.lock().expect("events lock");
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].input_tokens, Some(4));
        assert_eq!(events[0].response_bytes, compressed.len() as u64);
        assert!(events[0].usage_complete);
    }

    #[tokio::test]
    async fn compressed_json_is_observed_without_changing_encoded_bytes() {
        let sink = Arc::new(Sink::default());
        let (telemetry, worker) = UsageTelemetry::new(sink.clone());
        let mut request = tracker(&telemetry);
        request.observe_response(Some(b"application/json"), Some(b"gzip"));
        let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
        encoder
            .write_all(
                br#"{"usage":{"input_tokens":8,"output_tokens":13,"cache_read_input_tokens":2}}"#,
            )
            .expect("gzip JSON");
        let compressed = encoder.finish().expect("gzip finish");
        for part in compressed.chunks(2) {
            request.observe_chunk(part);
        }
        request.finish(RequestOutcome::Completed);
        drop(request);
        drain(telemetry, worker).await;
        let events = sink.events.lock().expect("events lock");
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].input_tokens, Some(8));
        assert_eq!(events[0].output_tokens, Some(13));
        assert_eq!(events[0].cache_read_tokens, Some(2));
        assert_eq!(events[0].response_bytes, compressed.len() as u64);
        assert!(events[0].usage_complete);
    }

    #[tokio::test]
    async fn one_compressed_chunk_with_excessive_expansion_is_unobserved() {
        let sink = Arc::new(Sink::default());
        let (telemetry, worker) = UsageTelemetry::new(sink.clone());
        let mut request = tracker(&telemetry);
        request.observe_response(Some(b"text/event-stream"), Some(b"gzip"));
        let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
        for _ in 0..=(MAX_OBSERVED_BYTES / 3) {
            encoder.write_all(b":\n\n").expect("gzip padding");
        }
        let compressed = encoder.finish().expect("gzip finish");
        request.observe_chunk(&compressed);
        request.finish(RequestOutcome::Completed);
        drop(request);
        drain(telemetry, worker).await;
        let events = sink.events.lock().expect("events lock");
        assert_eq!(events.len(), 1);
        assert!(!events[0].usage_complete);
        assert_eq!(events[0].response_bytes, compressed.len() as u64);
    }

    #[tokio::test]
    async fn malformed_truncated_and_cancelled_streams_are_partial() {
        let sink = Arc::new(Sink::default());
        let (telemetry, worker) = UsageTelemetry::new(sink.clone());
        let mut malformed = tracker(&telemetry);
        malformed.observe_response(Some(b"text/event-stream"), None);
        malformed.observe_chunk(b"data: {malformed}\n\n");
        malformed.finish(RequestOutcome::Completed);
        drop(malformed);
        let mut truncated = tracker(&telemetry);
        truncated.observe_response(Some(b"text/event-stream"), None);
        truncated.observe_chunk(b"data: {\"type\":\"message_delta\"");
        drop(truncated);
        drain(telemetry, worker).await;
        let events = sink.events.lock().expect("events lock");
        assert_eq!(events.len(), 2);
        assert!(!events[0].usage_complete);
        assert!(!events[1].usage_complete);
        assert_eq!(events[1].outcome, RequestOutcome::Cancelled);
    }

    #[tokio::test]
    async fn storage_failure_counts_one_loss_in_next_success() {
        let sink = Arc::new(Sink::default());
        sink.failures.store(1, Ordering::Release);
        let (telemetry, worker) = UsageTelemetry::new(sink.clone());
        for _ in 0..2 {
            let mut request = tracker(&telemetry);
            request.observe_response(Some(b"application/json"), None);
            request.observe_chunk(br#"{"usage":{"input_tokens":2,"output_tokens":3}}"#);
            request.finish(RequestOutcome::Completed);
        }
        drain(telemetry, worker).await;
        let events = sink.events.lock().expect("events lock");
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].dropped_events, 1);
        assert_eq!(events[0].input_tokens, Some(2));
    }

    #[tokio::test]
    async fn full_queue_never_waits_for_slow_storage_and_counts_losses() {
        let sink = Arc::new(SlowSink {
            events: Mutex::new(Vec::new()),
            entered: tokio::sync::Semaphore::new(0),
            release: tokio::sync::Semaphore::new(0),
        });
        let (telemetry, worker) = UsageTelemetry::new(sink.clone());
        tracker(&telemetry).finish_without_observation(RequestOutcome::Failed);
        let entered = sink.entered.acquire().await.expect("worker entered");
        entered.forget();
        tokio::time::timeout(std::time::Duration::from_secs(1), async {
            for _ in 0..TELEMETRY_QUEUE_CAPACITY + 5 {
                tracker(&telemetry).finish_without_observation(RequestOutcome::Failed);
            }
        })
        .await
        .expect("response-side send did not wait for storage");
        sink.release.add_permits(1);
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            loop {
                if sink.events.lock().expect("events lock").len() == TELEMETRY_QUEUE_CAPACITY + 1 {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("worker drains queued events");
        tracker(&telemetry).finish_without_observation(RequestOutcome::Failed);
        drain(telemetry, worker).await;
        let events = sink.events.lock().expect("events lock");
        assert_eq!(events.len(), TELEMETRY_QUEUE_CAPACITY + 2);
        assert_eq!(
            events.iter().map(|event| event.dropped_events).sum::<u64>(),
            5
        );
    }
}
