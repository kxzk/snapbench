use anyhow::{Context, Result};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use serde::{Deserialize, Serialize};
use std::net::UdpSocket;
use std::time::{Duration, Instant};

#[derive(Default)]
struct CliArgs {
    model: String,
    max_iterations: Option<u32>,
    benchmark: bool,
}

fn parse_args() -> CliArgs {
    let args: Vec<String> = std::env::args().collect();
    let mut cli = CliArgs {
        model: "google/gemini-3-flash-preview".to_string(),
        ..Default::default()
    };

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--model" => {
                i += 1;
                if i < args.len() {
                    cli.model = args[i].clone();
                }
            }
            "--max-iterations" => {
                i += 1;
                if i < args.len() {
                    cli.max_iterations = args[i].parse().ok();
                }
            }
            "--benchmark" => {
                cli.benchmark = true;
            }
            _ => {}
        }
        i += 1;
    }
    cli
}

#[derive(Serialize)]
struct BenchMetrics {
    model: String,
    status: String,
    iterations: u32,
    movements: u32,
    input_tokens: u64,
    output_tokens: u64,
    creatures_found: u8,
    creature_times_ms: Vec<u64>,
    total_ms: u64,
    failed_identifies: u32,
    stuck_events: u32,
    api_latencies_ms: Vec<u64>,
    min_distance_to_creature: Option<f32>,
}

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

    }
}

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

fn send_command(socket: &UdpSocket, cmd: &str) -> Result<String> {
    socket.send(cmd.as_bytes())?;
    let mut buf = [0u8; 256];
    let n = socket.recv(&mut buf)?;
    Ok(String::from_utf8_lossy(&buf[..n]).to_string())
}

struct LlmResult {
    commands: Vec<String>,
    input_tokens: u64,
    output_tokens: u64,
    latency_ms: u64,
}

async fn call_llm(
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
    let latency_ms = call_start.elapsed().as_millis() as u64;

    let status = resp.status();
    if !status.is_success() {
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("API error {}: {}", status, body);
    }

    let chat_resp: ChatResponse = resp.json().await.context("Failed to parse API response")?;

    let (input_tokens, output_tokens) = chat_resp
        .usage
        .map(|u| (u.prompt_tokens, u.completion_tokens))
        .unwrap_or((0, 0));

    let content = chat_resp
        .choices
        .first()
        .map(|c| c.message.content.clone())
        .unwrap_or_default();

    if !benchmark {
        println!("LLM response: {}", content);
    }

    let json_start = content.find('[').unwrap_or(0);
    let json_end = content.rfind(']').map(|i| i + 1).unwrap_or(content.len());
    let json_str = &content[json_start..json_end];

    let commands: Vec<String> =
        serde_json::from_str(json_str).unwrap_or_else(|_| vec!["forward".to_string()]);

    Ok(LlmResult {
        commands,
        input_tokens,
        output_tokens,
        latency_ms,
    })
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = parse_args();
    let api_key = std::env::var("OPENROUTER_API_KEY").context("OPENROUTER_API_KEY not set")?;

    let socket = UdpSocket::bind("0.0.0.0:0")?;
    socket.connect("127.0.0.1:9999")?;
    socket.set_read_timeout(Some(Duration::from_secs(2)))?;

    let client = reqwest::Client::new();
    let mut state = DroneState::default();

    // Metrics tracking
    let start_time = Instant::now();
    let mut iterations: u32 = 0;
    let mut movements: u32 = 0;
    let mut input_tokens: u64 = 0;
    let mut output_tokens: u64 = 0;
    let mut creature_times_ms: Vec<u64> = Vec::new();
    let mut failed_identifies: u32 = 0;
    let mut stuck_events: u32 = 0;
    let mut api_latencies_ms: Vec<u64> = Vec::new();
    let mut min_distance_to_creature: f32 = f32::INFINITY;
    let mut last_creatures_found: u8 = 0;

    if !args.benchmark {
        println!("LLM Drone Controller started");
        println!("Model: {}", args.model);
        println!("Waiting for simulation...");
    }
    let loop_delay = Duration::from_millis(500);

    let mut final_status = String::new();
    loop {
        iterations += 1;

        // Check max iterations limit
        if let Some(max) = args.max_iterations {
            if iterations > max {
                final_status = "max_iterations".to_string();
                break;
            }
        }

        let resp = send_command(&socket, "screenshot")?;
        if !args.benchmark {
            println!("Screenshot: {}", resp);
        }

        let image = tokio::fs::read("screenshot.png")
            .await
            .context("Failed to read screenshot.png")?;
        let b64 = BASE64.encode(&image);

        let llm_result = call_llm(&client, &api_key, &args.model, &b64, &state, args.benchmark).await?;

        // Accumulate metrics
        input_tokens += llm_result.input_tokens;
        output_tokens += llm_result.output_tokens;
        api_latencies_ms.push(llm_result.latency_ms);

        if !args.benchmark {
            println!("Executing: {:?}", llm_result.commands);
        }

        state.push_commands(llm_result.commands.clone());

        for cmd in llm_result.commands {
            let resp = send_command(&socket, &cmd)?;
            if !args.benchmark {
                println!("  {} -> {}", cmd, resp);
            }

            // Count movements (all commands except identify)
            if cmd != "identify" {
                movements += 1;
            }

            // Track failed identifies
            if cmd == "identify" && resp.starts_with("FAIL") {
                failed_identifies += 1;
            }

            state.update(&resp);

            // Track minimum distance to any creature
            if let Some(dist) = resp
                .split_whitespace()
                .find_map(|s| s.strip_prefix("min_dist="))
                .and_then(|v| v.parse::<f32>().ok())
            {
                min_distance_to_creature = min_distance_to_creature.min(dist);
            }

            // Track creature discovery time
            if state.creatures_found > last_creatures_found {
                creature_times_ms.push(start_time.elapsed().as_millis() as u64);
                last_creatures_found = state.creatures_found;
            }

            if state.game_over {
                if !args.benchmark {
                    println!(
                        "Game complete! Found all {} creatures.",
                        state.creatures_found
                    );
                }
                final_status = "complete".to_string();
                break;
            }
        }

        if state.game_over {
            break;
        }

        // Record position after each iteration for stuck detection
        state.record_position();
        if state.is_stuck() {
            stuck_events += 1;
            if !args.benchmark {
                println!("⚠️  Stuck detected at ({:.1}, {:.1}, {:.1})", state.x, state.y, state.z);
            }
        }

        if !args.benchmark {
            println!("---");
        }
        tokio::time::sleep(loop_delay).await;
    }

    let total_ms = start_time.elapsed().as_millis() as u64;

    if args.benchmark {
        let metrics = BenchMetrics {
            model: args.model,
            status: final_status,
            iterations,
            movements,
            input_tokens,
            output_tokens,
            creatures_found: state.creatures_found,
            creature_times_ms,
            total_ms,
            failed_identifies,
            stuck_events,
            api_latencies_ms,
            min_distance_to_creature: if min_distance_to_creature.is_infinite() {
                None
            } else {
                Some(min_distance_to_creature)
            },
        };
        println!("{}", serde_json::to_string(&metrics)?);
    }

    Ok(())
}
