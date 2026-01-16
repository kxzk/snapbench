use anyhow::{Context, Result};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use serde::{Deserialize, Serialize};
use std::net::UdpSocket;
use std::time::Duration;

const SYSTEM_PROMPT: &str = r#"
You pilot a drone hunting 3 creatures in a 64x64x64 world.

COMMANDS: forward, backward, left, right, up, down, rotate_left, rotate_right, identify

VISUAL TARGETS:
- Blocky animal shapes: pink pigs, white sheep, brown dogs, orange cats
- They glow faintly and contrast against green/brown terrain
- Identify only when creature is centered and close (appears large)

NAVIGATION:
- yaw: 0=+Z, 90=+X, 180=-Z, 270=-X
- Stay at altitude 15-25 for best ground visibility
- Near edges (x or z < 5 or > 59): rotate toward center before moving

SEARCH PATTERN:
- Sweep systematically — don't wander randomly
- After hitting an edge: rotate 90°, step sideways, rotate 90°, continue opposite direction

FAILED IDENTIFICATION:
- If identify fails on a visible creature, you're too far — move forward and try again
- Still failing? Get MUCH closer — you may need to be nearly touching it (creature fills most of frame)
- Lower altitude (down) if needed to match creature height, then continue approaching
- Don't abandon a spotted creature until identified or confirmed gone

Before answering, silently consider:
1. Do I see a creature shape? Where in frame?
2. Am I near an edge? Which direction is center?
3. What heading covers unexplored terrain?

Respond with ONLY a JSON array of 1-5 commands."#;

#[derive(Default)]
struct DroneState {
    x: f32,
    y: f32,
    z: f32,
    yaw: f32,
    creatures_found: u8,
    game_over: bool,
    recent_commands: Vec<Vec<String>>,
}

impl DroneState {
    fn push_commands(&mut self, commands: Vec<String>) {
        if self.recent_commands.len() >= 3 {
            self.recent_commands.remove(0);
        }
        self.recent_commands.push(commands);
    }

    fn format_history(&self) -> String {
        if self.recent_commands.is_empty() {
            return "none".into();
        }
        self.recent_commands
            .iter()
            .map(|cmds| format!("{cmds:?}"))
            .collect::<Vec<_>>()
            .join(" → ")
    }

    fn update(&mut self, response: &str) {
        if response.contains("ALL CREATURES FOUND") || self.creatures_found >= 3 {
            self.game_over = true;
            return;
        }

        for part in response.split_whitespace() {
            let parsed = match part.split_once('=') {
                Some(("x", v)) => v.parse().ok().map(|n| self.x = n),
                Some(("y", v)) => v.parse().ok().map(|n| self.y = n),
                Some(("z", v)) => v.parse().ok().map(|n| self.z = n),
                Some(("yaw", v)) => v.parse().ok().map(|n| self.yaw = n),
                Some(("remaining", v)) => {
                    v.parse::<u8>().ok().map(|n| self.creatures_found = 3 - n)
                }
                _ => None,
            };
            let _ = parsed;
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

async fn call_llm(
    client: &reqwest::Client,
    api_key: &str,
    image_b64: &str,
    state: &DroneState,
) -> Result<Vec<String>> {
    let user_content = format!(
        "Position: x={:.1} y={:.1} z={:.1} yaw={:.1}\n\
         Creatures found: {}/3\n\
         Recent commands: {}\n\n\
         What commands should I execute?",
        state.x,
        state.y,
        state.z,
        state.yaw,
        state.creatures_found,
        state.format_history()
    );

    let request = ChatRequest {
        model: "google/gemini-3-flash-preview",
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

    let commands: Vec<String> =
        serde_json::from_str(json_str).unwrap_or_else(|_| vec!["forward".to_string()]);

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

        state.push_commands(commands.clone());

        for cmd in commands {
            let resp = send_command(&socket, &cmd)?;
            println!("  {} -> {}", cmd, resp);
            state.update(&resp);

            if state.game_over {
                println!(
                    "Game complete! Found all {} creatures.",
                    state.creatures_found
                );
                return Ok(());
            }
        }

        println!("---");
        tokio::time::sleep(Duration::from_secs(3)).await;
    }
}
