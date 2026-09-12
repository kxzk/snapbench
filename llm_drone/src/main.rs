mod client;
mod metrics;
mod protocol;
mod simulator;
mod state;

use anyhow::{Context, Result};
use base64::{Engine, engine::general_purpose::STANDARD as BASE64};
use client::call_llm;
use metrics::BenchMetrics;
use protocol::{Action, Request};
use simulator::Simulator;
use state::DroneState;
use std::time::{Duration, Instant};

const CHECKPOINT_FILE: &str = "bench_checkpoint.json";

struct CliArgs {
    model: String,
    max_iterations: Option<u32>,
    benchmark: bool,
}

fn parse_args() -> Result<CliArgs> {
    let mut args = std::env::args().skip(1);
    let mut options = CliArgs {
        model: "google/gemini-3-flash-preview".into(),
        max_iterations: None,
        benchmark: false,
    };
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--model" => options.model = args.next().context("--model requires a value")?,
            "--max-iterations" => {
                let count = args
                    .next()
                    .context("--max-iterations requires a value")?
                    .parse()?;
                anyhow::ensure!(count > 0, "Iteration count must be positive");
                options.max_iterations = Some(count);
            }
            "--benchmark" => options.benchmark = true,
            _ => anyhow::bail!("Unknown argument: {arg}"),
        }
    }
    Ok(options)
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let args = parse_args()?;
    let api_key = std::env::var("OPENROUTER_API_KEY").context("OPENROUTER_API_KEY not set")?;
    let mut simulator = Simulator::connect().await?;
    let initial = simulator
        .request(Request::Reset {
            seed: None,
            scenario: None,
        })
        .await?;
    anyhow::ensure!(
        initial.scenario == "island-photo-v2",
        "The VLM photography controller requires --scenario island"
    );
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(60))
        .build()?;
    let mut state = DroneState::default();
    state.update(&initial);
    let mut metrics = BenchMetrics {
        model: args.model.clone(),
        scenario: initial.scenario,
        replay_path: simulator.replay_path.clone(),
        status: "in_progress".into(),
        ..Default::default()
    };
    let start = Instant::now();
    if !args.benchmark {
        println!("LLM Drone Controller started\nModel: {}", args.model);
    }

    loop {
        if args
            .max_iterations
            .is_some_and(|max| metrics.iterations >= max)
        {
            metrics.status = "max_iterations".into();
            break;
        }
        metrics.iterations += 1;
        let screenshot = simulator.request(Request::Observe).await?;
        state.update(&screenshot);
        state.record_position();
        let image = Simulator::image(&screenshot).await?;
        let b64 = BASE64.encode(&image);
        let commands =
            match call_llm(&client, &api_key, &args.model, &b64, &state, args.benchmark).await {
                Ok(result) => {
                    metrics.input_tokens += result.input_tokens;
                    metrics.output_tokens += result.output_tokens;
                    metrics.api_latencies_ms.push(result.latency_ms);
                    result.commands
                }
                Err(error) => Err(error),
            };
        match commands {
            Ok(commands) => {
                for command in &commands {
                    let response = simulator
                        .request(Request::Act {
                            command: *command,
                            ticks: 30,
                        })
                        .await?;
                    if !args.benchmark {
                        println!(
                            "{command:?} -> {} at tick {}",
                            response.status, response.tick
                        );
                    }
                    if *command != Action::Identify {
                        metrics.movements += 1;
                    } else if response.status == "no_subject" {
                        metrics.failed_identifies += 1;
                    }
                    state.update(&response);
                    metrics.simulation_ticks = response.tick;
                    if state.creatures_found > metrics.creatures_found {
                        metrics
                            .creature_times_ms
                            .push(start.elapsed().as_millis() as u64);
                        metrics.creatures_found = state.creatures_found;
                    }
                    if state.game_over() {
                        metrics.status = "complete".into();
                        break;
                    }
                }
                state.push_commands(commands);
            }
            Err(error) => {
                metrics.api_errors += 1;
                if !args.benchmark {
                    eprintln!("API error: {error}");
                }
            }
        }
        metrics.total_ms = start.elapsed().as_millis() as u64;
        if state.game_over() {
            if !args.benchmark {
                println!(
                    "Game complete! Found all {} creatures.",
                    state.creatures_found
                );
            }
            break;
        }
        if state.is_stuck() {
            metrics.stuck_events += 1;
        }
        if args.benchmark {
            metrics
                .save_checkpoint(std::path::Path::new(CHECKPOINT_FILE))
                .await?;
        }
    }
    metrics.total_ms = start.elapsed().as_millis() as u64;
    if args.benchmark {
        println!("{}", serde_json::to_string(&metrics)?);
        let _ = tokio::fs::remove_file(CHECKPOINT_FILE).await;
    }
    Ok(())
}
