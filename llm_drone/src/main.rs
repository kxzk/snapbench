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
- When you spot one: approach until touching, THEN identify (not before)

NAVIGATION:
- yaw: 0=+Z, 90=+X, 180=-Z, 270=-X
- Stay at altitude 15-25 for best ground visibility
- Near edges (x or z < 5 or > 59): rotate toward center before moving

STUCK DETECTION — CRITICAL:
- ALWAYS check your recent commands and position history before deciding
- If position barely changed over 2-3 iterations: you're stuck (obstacle or edge)
- If you sent the same movement 2+ times with no progress: STOP and rotate 90° to try a new direction
- Pattern like [forward,forward] → [forward,forward] with same position = STUCK → rotate_left or rotate_right
- Don't repeat failed approaches — if forward didn't work, try rotate + forward in new direction

SEARCH STRATEGY:
- Sweep systematically, don't wander randomly
- After hitting obstacle/edge: rotate 90°, move sideways, rotate back, continue
- Vary your approach — if one path is blocked, try altitude changes or lateral movement
- Use rotate commands to scan surroundings when unsure where creatures are

IDENTIFICATION — CRITICAL:
- You must be TOUCHING the creature to identify it — creature should fill nearly the ENTIRE frame
- Do NOT call identify until you are extremely close (creature obscures most of the view)
- If you can see terrain around the creature, you're TOO FAR — keep moving forward
- Approach sequence: spot creature → move forward repeatedly until creature fills frame → then identify
- If identify fails: you're not close enough — move forward more, adjust altitude to match creature height
- Only give up on a creature if you've approached and it's clearly gone

REASONING (do this silently before responding):
1. Check position history — am I making progress or stuck in place?
2. Check command history — am I repeating the same thing? If so, try something different
3. Do I see a creature? If yes, approach and identify. If no, continue search pattern
4. Am I near an edge or obstacle? Rotate to find clear path

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
    position_history: Vec<(f32, f32, f32)>, // track last few positions
}

impl DroneState {
    fn push_commands(&mut self, commands: Vec<String>) {
        if self.recent_commands.len() >= 5 {
            self.recent_commands.remove(0);
        }
        self.recent_commands.push(commands);
    }

    fn record_position(&mut self) {
        if self.position_history.len() >= 5 {
            self.position_history.remove(0);
        }
        self.position_history.push((self.x, self.y, self.z));
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

    fn format_position_history(&self) -> String {
        if self.position_history.len() < 2 {
            return "insufficient data".into();
        }
        self.position_history
            .iter()
            .map(|(x, y, z)| format!("({x:.1},{y:.1},{z:.1})"))
            .collect::<Vec<_>>()
            .join(" → ")
    }

    fn is_stuck(&self) -> bool {
        if self.position_history.len() < 3 {
            return false;
        }
        // Check if last 3 positions are nearly identical
        let recent: Vec<_> = self.position_history.iter().rev().take(3).collect();
        let (x0, y0, z0) = recent[0];
        recent.iter().skip(1).all(|(x, y, z)| {
            (x - x0).abs() < 0.5 && (y - y0).abs() < 0.5 && (z - z0).abs() < 0.5
        })
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
    let stuck_warning = if state.is_stuck() {
        "\n⚠️ WARNING: You appear STUCK — position unchanged for 3 iterations. MUST rotate to try new direction!"
    } else {
        ""
    };

    let user_content = format!(
        "Position: x={:.1} y={:.1} z={:.1} yaw={:.1}\n\
         Creatures found: {}/3\n\
         Recent commands: {}\n\
         Position history: {}{}\n\n\
         What commands should I execute?",
        state.x,
        state.y,
        state.z,
        state.yaw,
        state.creatures_found,
        state.format_history(),
        state.format_position_history(),
        stuck_warning
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
    let loop_delay = Duration::from_millis(500);

    loop {
        let resp = send_command(&socket, "screenshot")?;
        println!("Screenshot: {}", resp);

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

        // Record position after each iteration for stuck detection
        state.record_position();
        if state.is_stuck() {
            println!("⚠️  Stuck detected at ({:.1}, {:.1}, {:.1})", state.x, state.y, state.z);
        }

        println!("---");
        tokio::time::sleep(loop_delay).await;
    }
}
