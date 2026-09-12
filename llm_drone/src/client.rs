use crate::protocol::Action;
use crate::state::DroneState;
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::time::Instant;

const SYSTEM_PROMPT: &str = include_str!("prompt.txt");

#[derive(Serialize)]
struct ChatRequest {
    model: String,
    messages: Vec<Message>,
    max_tokens: u32,
}

#[derive(Serialize)]
struct Message {
    role: &'static str,
    content: MessageContent,
}

#[derive(Serialize)]
#[serde(untagged)]
enum MessageContent {
    Text(String),
    Parts(Vec<ContentPart>),
}

#[derive(Serialize)]
#[serde(tag = "type")]
enum ContentPart {
    #[serde(rename = "text")]
    Text { text: String },
    #[serde(rename = "image_url")]
    ImageUrl { image_url: ImageUrl },
}

#[derive(Serialize)]
struct ImageUrl {
    url: String,
}

#[derive(Deserialize)]
struct ChatResponse {
    choices: Vec<Choice>,
    usage: Option<Usage>,
}

#[derive(Deserialize)]
struct Usage {
    prompt_tokens: u64,
    completion_tokens: u64,
}

#[derive(Deserialize)]
struct Choice {
    message: ResponseMessage,
}

#[derive(Deserialize)]
struct ResponseMessage {
    content: String,
}

pub struct LlmResult {
    pub commands: Result<Vec<Action>>,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub latency_ms: u64,
}

pub async fn call_llm(
    client: &reqwest::Client,
    api_key: &str,
    model: &str,
    image_b64: &str,
    state: &DroneState,
    benchmark: bool,
) -> Result<LlmResult> {
    let stuck_warning = if state.is_stuck() {
        "\n⚠️ WARNING: You appear STUCK — position unchanged for 3 iterations. MUST rotate to try new direction!"
    } else {
        ""
    };

    let user_content = format!(
        "Position: x={:.1} y={:.1} z={:.1} yaw={:.1} camera_pitch={:.1} tick={}\n\
         Creatures found: {}/3\n\
         Recent commands: {}\n\
         Position history: {}{}\n\n\
         What commands should I execute?",
        state.x,
        state.y,
        state.z,
        state.yaw,
        state.pitch,
        state.tick,
        state.creatures_found,
        state.format_history(),
        state.format_position_history(),
        stuck_warning
    );

    let request = ChatRequest {
        model: model.to_string(),
        messages: vec![
            Message {
                role: "system",
                content: MessageContent::Text(SYSTEM_PROMPT.to_string()),
            },
            Message {
                role: "user",
                content: MessageContent::Parts(vec![
                    ContentPart::ImageUrl {
                        image_url: ImageUrl {
                            url: format!("data:image/png;base64,{}", image_b64),
                        },
                    },
                    ContentPart::Text { text: user_content },
                ]),
            },
        ],
        max_tokens: 256,
    };

    let call_start = Instant::now();
    let resp = client
        .post("https://openrouter.ai/api/v1/chat/completions")
        .header("Authorization", format!("Bearer {}", api_key))
        .json(&request)
        .send()
        .await
        .context("Failed to call OpenRouter API")?;

    let status = resp.status();
    if !status.is_success() {
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("API error {}: {}", status, body);
    }

    let chat_resp: ChatResponse = resp.json().await.context("Failed to parse API response")?;
    let latency_ms = call_start.elapsed().as_millis() as u64;

    let (input_tokens, output_tokens) = chat_resp
        .usage
        .map(|u| (u.prompt_tokens, u.completion_tokens))
        .unwrap_or((0, 0));

    let content = chat_resp
        .choices
        .first()
        .map(|c| c.message.content.as_str())
        .unwrap_or_default();

    if !benchmark {
        println!("LLM response: {}", content);
    }

    // Invalid commands still consumed API tokens; preserve usage for accounting.
    let commands = parse_commands(content);

    Ok(LlmResult {
        commands,
        input_tokens,
        output_tokens,
        latency_ms,
    })
}

fn parse_commands(content: &str) -> Result<Vec<Action>> {
    let start = content.find('[').context("Missing command array")?;
    let end = content.rfind(']').context("Missing command array end")?;
    let json = content
        .get(start..=end)
        .context("Invalid command array bounds")?;
    let commands: Vec<Action> = serde_json::from_str(json).context("Invalid command array")?;
    anyhow::ensure!((1..=5).contains(&commands.len()), "Expected 1-5 commands");
    Ok(commands)
}

#[cfg(test)]
mod tests {
    use super::parse_commands;

    #[test]
    fn malformed_commands_never_trigger_fallback_movement() {
        for content in [
            "] [",
            "not json",
            "[]",
            "[\"turn_left\"]",
            "[\"forward\", 5]",
        ] {
            assert!(parse_commands(content).is_err(), "{content}");
        }
    }

    #[test]
    fn commands_can_be_extracted_from_markdown() {
        assert_eq!(
            parse_commands("```json\n[\"up\",\"identify\"]\n```").unwrap(),
            [
                crate::protocol::Action::Up,
                crate::protocol::Action::Identify
            ]
        );
    }
}
