//! Exact `ToolSearch` spelling changes for the z.ai Anthropic preset.

use std::ops::Range;

use serde::Deserialize;
use serde_json::value::RawValue;
use zeroize::Zeroizing;

const CLIENT_NAME: &str = "ToolSearch";
const UPSTREAM_NAME: &str = "ToolSearch_";
pub(crate) const EVENT_LIMIT: usize = 1 << 20;

#[derive(Deserialize)]
struct Object<'a> {
    #[serde(borrow)]
    content: Option<&'a RawValue>,
    #[serde(borrow)]
    content_block: Option<&'a RawValue>,
    #[serde(borrow)]
    #[serde(rename = "type")]
    kind: Option<&'a RawValue>,
    #[serde(borrow)]
    messages: Option<&'a RawValue>,
    #[serde(borrow)]
    name: Option<&'a RawValue>,
    #[serde(borrow)]
    tool_choice: Option<&'a RawValue>,
    #[serde(borrow)]
    tool_name: Option<&'a RawValue>,
    #[serde(borrow)]
    tools: Option<&'a RawValue>,
}

#[derive(Clone)]
struct Edit {
    range: Range<usize>,
    replacement: &'static [u8],
}

fn object(raw: &str) -> Result<Object<'_>, &'static str> {
    serde_json::from_str(raw).map_err(|_| "invalid_toolsearch_json")
}

fn array(raw: &RawValue) -> Result<Vec<&RawValue>, &'static str> {
    serde_json::from_str(raw.get()).map_err(|_| "invalid_toolsearch_json")
}

fn raw_string(raw: &RawValue) -> Result<String, &'static str> {
    serde_json::from_str(raw.get()).map_err(|_| "invalid_toolsearch_json")
}

fn is_array(raw: &RawValue) -> bool {
    raw.get().starts_with('[')
}

fn add_name(
    body: &str,
    raw: Option<&RawValue>,
    from: &str,
    replacement: &'static [u8],
    edits: &mut Vec<Edit>,
) -> Result<(), &'static str> {
    let Some(raw) = raw else { return Ok(()) };
    if raw_string(raw)? != from {
        return Ok(());
    }
    let start = (raw.get().as_ptr() as usize)
        .checked_sub(body.as_ptr() as usize)
        .ok_or("invalid_toolsearch_json")?;
    let end = start + raw.get().len();
    if end > body.len() {
        return Err("invalid_toolsearch_json");
    }
    edits.push(Edit {
        range: start..end,
        replacement,
    });
    Ok(())
}

fn content_items<'a>(
    body: &'a str,
    raw: &'a RawValue,
    from: &str,
    replacement: &'static [u8],
    edits: &mut Vec<Edit>,
    allow_tool_result: bool,
) -> Result<(), &'static str> {
    if !is_array(raw) {
        return Ok(());
    }
    for item in array(raw)? {
        let item = object(item.get())?;
        match item.kind.map(raw_string).transpose()?.as_deref() {
            Some("tool_use") => add_name(body, item.name, from, replacement, edits)?,
            Some("tool_reference") => {
                add_name(body, item.tool_name, from, replacement, edits)?;
            }
            Some("tool_result") => {
                if !allow_tool_result {
                    return Err("toolsearch_nested_tool_result");
                }
                if let Some(content) = item.content {
                    content_items(body, content, from, replacement, edits, false)?;
                }
            }
            _ => {}
        }
    }
    Ok(())
}

fn apply_edits(original: &Zeroizing<Vec<u8>>, edits: &mut [Edit]) -> Zeroizing<Vec<u8>> {
    edits.sort_by_key(|edit| edit.range.start);
    let mut output = Zeroizing::new(Vec::with_capacity(original.len() + edits.len()));
    let mut cursor = 0;
    for edit in edits {
        output.extend_from_slice(&original[cursor..edit.range.start]);
        output.extend_from_slice(edit.replacement);
        cursor = edit.range.end;
    }
    output.extend_from_slice(&original[cursor..]);
    output
}

pub(crate) fn request(body: &mut Zeroizing<Vec<u8>>) -> Result<bool, &'static str> {
    let text = std::str::from_utf8(body).map_err(|_| "invalid_toolsearch_json")?;
    let root = object(text)?;
    let mut edits = Vec::new();
    if let Some(tools) = root.tools {
        for tool in array(tools)? {
            let tool = object(tool.get())?;
            if tool.name.map(raw_string).transpose()?.as_deref() == Some(UPSTREAM_NAME) {
                return Err("toolsearch_name_collision");
            }
            add_name(
                text,
                tool.name,
                CLIENT_NAME,
                br#""ToolSearch_""#,
                &mut edits,
            )?;
        }
    }
    if let Some(choice) = root.tool_choice {
        let choice = object(choice.get())?;
        if choice.kind.map(raw_string).transpose()?.as_deref() == Some("tool") {
            add_name(
                text,
                choice.name,
                CLIENT_NAME,
                br#""ToolSearch_""#,
                &mut edits,
            )?;
        }
    }
    if let Some(messages) = root.messages {
        for message in array(messages)? {
            if let Some(content) = object(message.get())?.content {
                content_items(
                    text,
                    content,
                    CLIENT_NAME,
                    br#""ToolSearch_""#,
                    &mut edits,
                    true,
                )?;
            }
        }
    }
    if edits.is_empty() {
        return Ok(false);
    }
    *body = apply_edits(body, &mut edits);
    Ok(true)
}

pub(crate) fn response(body: &mut Zeroizing<Vec<u8>>) -> Result<bool, &'static str> {
    let text = std::str::from_utf8(body).map_err(|_| "invalid_toolsearch_json")?;
    let root = object(text)?;
    let mut edits = Vec::new();
    if let Some(content) = root.content {
        content_items(
            text,
            content,
            UPSTREAM_NAME,
            br#""ToolSearch""#,
            &mut edits,
            true,
        )?;
    }
    if edits.is_empty() {
        return Ok(false);
    }
    *body = apply_edits(body, &mut edits);
    Ok(true)
}

fn sse_lines(text: &str) -> Vec<(&str, &str)> {
    let bytes = text.as_bytes();
    let mut lines = Vec::new();
    let mut start = 0;
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'\r' || bytes[index] == b'\n' {
            let end = index;
            index += 1;
            if bytes[end] == b'\r' && bytes.get(index) == Some(&b'\n') {
                index += 1;
            }
            lines.push((&text[start..end], &text[end..index]));
            start = index;
        } else {
            index += 1;
        }
    }
    if start < text.len() {
        lines.push((&text[start..], ""));
    }
    lines
}

pub(crate) fn event(event: &mut Zeroizing<Vec<u8>>) -> Result<bool, &'static str> {
    let text = std::str::from_utf8(event).map_err(|_| "invalid_toolsearch_event")?;
    let lines = sse_lines(text);
    let event_name = lines
        .iter()
        .filter_map(|(line, _)| line.strip_prefix("event:"))
        .next_back()
        .map(|value| value.strip_prefix(' ').unwrap_or(value));
    if event_name.is_some_and(|name| name != "content_block_start") {
        return Ok(false);
    }
    let mut data = Vec::new();
    let mut data_lines = 0;
    for (line, _) in &lines {
        if let Some(value) = line.strip_prefix("data:") {
            if data_lines > 0 {
                data.push(b'\n');
            }
            data.extend_from_slice(value.strip_prefix(' ').unwrap_or(value).as_bytes());
            data_lines += 1;
        }
    }
    if data.is_empty() || data == b"[DONE]" {
        return Ok(false);
    }
    let mut payload = Zeroizing::new(data);
    let payload_text = std::str::from_utf8(&payload).map_err(|_| "invalid_toolsearch_event")?;
    let root = match object(payload_text) {
        Ok(root) => root,
        Err(_) if event_name.is_none() => return Ok(false),
        Err(reason) => return Err(reason),
    };
    if root.kind.map(raw_string).transpose()?.as_deref() != Some("content_block_start") {
        return Ok(false);
    }
    let Some(block) = root.content_block else {
        return Ok(false);
    };
    let block = object(block.get())?;
    if block.kind.map(raw_string).transpose()?.as_deref() != Some("tool_use") {
        return Ok(false);
    }
    let mut edits = Vec::new();
    add_name(
        payload_text,
        block.name,
        UPSTREAM_NAME,
        br#""ToolSearch""#,
        &mut edits,
    )?;
    if edits.is_empty() {
        return Ok(false);
    }
    payload = apply_edits(&payload, &mut edits);
    let mut output = Zeroizing::new(Vec::with_capacity(event.len() + payload.len()));
    let mut emitted = false;
    for (line, ending) in lines {
        if line.starts_with("data:") {
            if !emitted {
                for part in payload.split(|byte| *byte == b'\n') {
                    output.extend_from_slice(b"data: ");
                    output.extend_from_slice(part);
                    output.extend_from_slice(ending.as_bytes());
                }
                emitted = true;
            }
        } else {
            output.extend_from_slice(line.as_bytes());
            output.extend_from_slice(ending.as_bytes());
        }
    }
    *event = output;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn buffer(input: &str) -> Zeroizing<Vec<u8>> {
        Zeroizing::new(input.as_bytes().to_vec())
    }

    #[test]
    fn request_aliases_only_structural_tool_names_and_keeps_other_bytes_exact() {
        let mut body = buffer(
            r#"{"model":"glm-4.7","n":123456789012345678901234567890,"n":42,"tools":[{"name":"ToolSearch","description":"say ToolSearch and \"name\":\"ToolSearch\""},{"name":"lookup","defer_loading":true}],"tool_choice":{"type":"tool","name":"ToolSearch"},"messages":[{"role":"assistant","content":[{"type":"tool_use","name":"ToolSearch","input":{"name":"ToolSearch"}},{"type":"tool_reference","tool_name":"ToolSearch"}]},{"role":"user","content":[{"type":"tool_result","content":[{"type":"text","text":"ToolSearch"},{"type":"tool_reference","tool_name":"ToolSearch"}]}]}]}"#,
        );
        assert_eq!(request(&mut body), Ok(true));
        let expected = r#"{"model":"glm-4.7","n":123456789012345678901234567890,"n":42,"tools":[{"name":"ToolSearch_","description":"say ToolSearch and \"name\":\"ToolSearch\""},{"name":"lookup","defer_loading":true}],"tool_choice":{"type":"tool","name":"ToolSearch_"},"messages":[{"role":"assistant","content":[{"type":"tool_use","name":"ToolSearch_","input":{"name":"ToolSearch"}},{"type":"tool_reference","tool_name":"ToolSearch_"}]},{"role":"user","content":[{"type":"tool_result","content":[{"type":"text","text":"ToolSearch"},{"type":"tool_reference","tool_name":"ToolSearch_"}]}]}]}"#;
        assert_eq!(&body[..], expected.as_bytes());
    }

    #[test]
    fn history_without_declarations_and_unrelated_requests() {
        let mut history =
            buffer(r#"{"messages":[{"content":[{"type":"tool_use","name":"ToolSearch"}]}]}"#);
        assert_eq!(request(&mut history), Ok(true));
        assert!(
            std::str::from_utf8(&history)
                .expect("UTF-8")
                .contains("ToolSearch_")
        );

        let input = r#"{"model":"glm-4.7","tools":[{"name":"lookup"}],"messages":[{"content":"ToolSearch"}]}"#;
        let mut unrelated = buffer(input);
        assert_eq!(request(&mut unrelated), Ok(false));
        assert_eq!(&unrelated[..], input.as_bytes());
    }

    #[test]
    fn existing_upstream_declaration_is_refused() {
        for input in [
            r#"{"tools":[{"name":"ToolSearch_"}]}"#,
            r#"{"tools":[{"name":"ToolSearch"},{"name":"ToolSearch_"}]}"#,
        ] {
            let mut body = buffer(input);
            assert_eq!(request(&mut body), Err("toolsearch_name_collision"));
            assert_eq!(&body[..], input.as_bytes());
        }
    }

    #[test]
    fn deeper_tool_results_are_refused_without_recursive_traversal() {
        let mut content = r#"{"type":"tool_reference","tool_name":"ToolSearch"}"#.to_owned();
        for _ in 0..4000 {
            content = format!(r#"{{"type":"tool_result","content":[{content}]}}"#);
        }
        let mut request_body = buffer(&format!(r#"{{"messages":[{{"content":[{content}]}}]}}"#));
        assert_eq!(
            request(&mut request_body),
            Err("toolsearch_nested_tool_result")
        );
        let mut response_body = buffer(&format!(r#"{{"content":[{content}]}}"#));
        assert_eq!(
            response(&mut response_body),
            Err("toolsearch_nested_tool_result")
        );
    }

    #[test]
    fn response_and_sse_change_only_tool_use_starts() {
        let mut json = buffer(
            r#"{"content":[{"type":"text","text":"ToolSearch_"},{"type":"tool_use","name":"ToolSearch_","input":{"name":"ToolSearch_"}}],"usage":{"output_tokens":3}}"#,
        );
        assert_eq!(response(&mut json), Ok(true));
        assert_eq!(
            &json[..],
            br#"{"content":[{"type":"text","text":"ToolSearch_"},{"type":"tool_use","name":"ToolSearch","input":{"name":"ToolSearch_"}}],"usage":{"output_tokens":3}}"#
        );
        let mut event = buffer(
            "event: content_block_start\r\ndata: {\"type\":\"content_block_start\",\"content_block\":{\"type\":\"tool_use\",\"name\":\"ToolSearch_\",\"input\":{}}}\r\n\r\n",
        );
        assert_eq!(super::event(&mut event), Ok(true));
        assert!(
            std::str::from_utf8(&event)
                .expect("UTF-8")
                .contains(r#""name":"ToolSearch""#)
        );
        assert!(event.ends_with(b"\r\n\r\n"));
        let original = "event: message\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":7}}\n\n";
        let mut usage = buffer(original);
        assert_eq!(super::event(&mut usage), Ok(false));
        assert_eq!(&usage[..], original.as_bytes());

        let unknown = "event: keepalive\ndata: plain text ToolSearch_\n\n";
        let mut unknown_event = buffer(unknown);
        assert_eq!(super::event(&mut unknown_event), Ok(false));
        assert_eq!(&unknown_event[..], unknown.as_bytes());

        let mut multiline = buffer(
            "event: content_block_start\ndata: {\"type\":\"content_block_start\",\ndata: \"content_block\":{\"type\":\"tool_use\",\"name\":\"ToolSearch_\"}}\n\n",
        );
        assert_eq!(super::event(&mut multiline), Ok(true));
        let restored = std::str::from_utf8(&multiline).expect("UTF-8");
        assert_eq!(
            restored
                .lines()
                .filter(|line| line.starts_with("data:"))
                .count(),
            2
        );
        assert!(restored.contains(r#""name":"ToolSearch""#));

        let mut last_event_wins = buffer(
            "event: keepalive\nevent: content_block_start\ndata: {\"type\":\"content_block_start\",\"content_block\":{\"type\":\"tool_use\",\"name\":\"ToolSearch_\"}}\n\n",
        );
        assert_eq!(super::event(&mut last_event_wins), Ok(true));

        for line_end in ["\r", "\n", "\r\n"] {
            let mut cr_event = buffer(&format!(
                "event: content_block_start{line_end}data: {{\"type\":\"content_block_start\",\"content_block\":{{\"type\":\"tool_use\",\"name\":\"ToolSearch_\"}}}}{line_end}{line_end}"
            ));
            assert_eq!(super::event(&mut cr_event), Ok(true));
            assert!(cr_event.ends_with(line_end.repeat(2).as_bytes()));
            assert!(
                std::str::from_utf8(&cr_event)
                    .expect("UTF-8")
                    .contains(r#""name":"ToolSearch""#)
            );
        }

        for unknown_name in [
            "  content_block_start",
            " content_block_start ",
            "\tcontent_block_start",
        ] {
            let original = format!(
                "event:{unknown_name}\ndata: {{\"type\":\"content_block_start\",\"content_block\":{{\"type\":\"tool_use\",\"name\":\"ToolSearch_\"}}}}\n\n"
            );
            let mut unknown = buffer(&original);
            assert_eq!(super::event(&mut unknown), Ok(false));
            assert_eq!(&unknown[..], original.as_bytes());
        }
    }
}
