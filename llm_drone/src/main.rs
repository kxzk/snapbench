use anyhow::{Context, Result};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use serde::{Deserialize, Serialize};
use std::net::UdpSocket;
use std::time::Duration;

const SYSTEM_PROMPT: &str = r#"You pilot a drone finding 3 creatures in a 3D world.

Commands: forward, backward, left, right, up, down, rotate_left, rotate_right, identify

Rules:
- identify works within 5 units of creature
- World is 128x128 units, start at (0, 20, 0)
- Creatures are animals (cats, dogs, pigs, sheep) on terrain
- Look for distinct shapes against grass/terrain

Respond with ONLY a JSON array of 1-5 commands.
Example: ["forward", "rotate_right", "forward", "identify"]"#;

#[derive(Default)]
struct DroneState {
    x: f32,
    y: f32,
    z: f32,
    yaw: f32,
    creatures_found: u8,
    game_over: bool,
}

impl DroneState {
    fn update(&mut self, response: &str) {
        if response.contains("ALL CREATURES FOUND") || self.creatures_found >= 3 {
            self.game_over = true;
            return;
        }

        for part in response.split_whitespace() {
            if let Some(val) = part.strip_prefix("x=") {
                self.x = val.parse().unwrap_or(self.x);
            } else if let Some(val) = part.strip_prefix("y=") {
                self.y = val.parse().unwrap_or(self.y);
            } else if let Some(val) = part.strip_prefix("z=") {
                self.z = val.parse().unwrap_or(self.z);
            } else if let Some(val) = part.strip_prefix("yaw=") {
                self.yaw = val.parse().unwrap_or(self.yaw);
            } else if let Some(val) = part.strip_prefix("remaining=") {
                if let Ok(remaining) = val.parse::<u8>() {
                    self.creatures_found = 3 - remaining;
                }
            }
        }

        if response.starts_with("OK:identified") {
            self.creatures_found += 1;
            if self.creatures_found >= 3 {
                self.game_over = true;
            }
        }
    }
}

#[derive(Serialize)]
struct ChatRequest {
    model: &'static str,
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
}

#[derive(Deserialize)]
struct Choice {
    message: ResponseMessage,
}

#[derive(Deserialize)]
struct ResponseMessage {
    content: String,
}

fn send_command(socket: &UdpSocket, cmd: &str) -> Result<String> {
    socket.send(cmd.as_bytes())?;
    let mut buf = [0u8; 256];
    let n = socket.recv(&mut buf)?;
    Ok(String::from_utf8_lossy(&buf[..n]).to_string())
}

async fn call_llm(client: &reqwest::Client, api_key: &str, image_b64: &str, state: &DroneState) -> Result<Vec<String>> {
    let user_content = format!(
        "Position: x={:.1} y={:.1} z={:.1} yaw={:.1}\nCreatures found: {}/3\n\nWhat commands should I execute?",
        state.x, state.y, state.z, state.yaw, state.creatures_found
    );

    let request = ChatRequest {
        model: "anthropic/claude-haiku-4.5",
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
    let content = chat_resp
        .choices
        .first()
        .map(|c| c.message.content.clone())
        .unwrap_or_default();

    println!("LLM response: {}", content);

    let json_start = content.find('[').unwrap_or(0);
    let json_end = content.rfind(']').map(|i| i + 1).unwrap_or(content.len());
    let json_str = &content[json_start..json_end];

    let commands: Vec<String> = serde_json::from_str(json_str).unwrap_or_else(|_| vec!["forward".to_string()]);

    Ok(commands)
}

#[tokio::main]
async fn main() -> Result<()> {
    let api_key = std::env::var("OPENROUTER_API_KEY").context("OPENROUTER_API_KEY not set")?;

    let socket = UdpSocket::bind("0.0.0.0:0")?;
    socket.connect("127.0.0.1:9999")?;
    socket.set_read_timeout(Some(Duration::from_secs(2)))?;

    let client = reqwest::Client::new();
    let mut state = DroneState::default();

    println!("LLM Drone Controller started");
    println!("Waiting for simulation...");

    loop {
        let resp = send_command(&socket, "screenshot")?;
        println!("Screenshot: {}", resp);

        tokio::time::sleep(Duration::from_millis(200)).await;

        let image = tokio::fs::read("screenshot.png")
            .await
            .context("Failed to read screenshot.png")?;
        let b64 = BASE64.encode(&image);

        let commands = call_llm(&client, &api_key, &b64, &state).await?;
        println!("Executing: {:?}", commands);

        for cmd in commands {
            let resp = send_command(&socket, &cmd)?;
            println!("  {} -> {}", cmd, resp);
            state.update(&resp);

            if state.game_over {
                println!("Game complete! Found all {} creatures.", state.creatures_found);
                return Ok(());
            }
        }

        println!("---");
        tokio::time::sleep(Duration::from_secs(5)).await;
    }
}
