use crate::protocol::{Envelope, Observation, Request, decode_reply};
use anyhow::{Context, Result};
use serde_json::json;
use std::io::Write;
use std::path::{Component, Path};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::net::UdpSocket;

pub struct Simulator {
    socket: UdpSocket,
    next_id: u64,
    replay: std::fs::File,
    pub replay_path: String,
}

impl Simulator {
    pub async fn connect() -> Result<Self> {
        let socket = UdpSocket::bind("127.0.0.1:0").await?;
        socket.connect("127.0.0.1:9999").await?;
        std::fs::create_dir_all(".snapbench/replays")?;
        let timestamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let replay_path = format!(".snapbench/replays/controller-{timestamp}.jsonl");
        let replay = std::fs::File::create(&replay_path)?;
        Ok(Self {
            socket,
            next_id: 1,
            replay,
            replay_path,
        })
    }

    pub async fn request(&mut self, operation: Request) -> Result<Observation> {
        let id = self.next_id;
        self.next_id += 1;
        let timeout = Duration::from_secs(3)
            + match &operation {
                Request::Act { ticks, .. } => Duration::from_secs_f64(f64::from(*ticks) / 120.0),
                _ => Duration::ZERO,
            };
        let mut request = Envelope {
            id,
            request: operation,
        };
        let data = serde_json::to_vec(&request)?;
        let mut buffer = [0u8; 2048];
        // Retries keep the same ID and bytes, so the server returns its cached reply.
        for _ in 0..3 {
            self.socket.send(&data).await?;
            let deadline = tokio::time::Instant::now() + timeout;
            loop {
                let received =
                    tokio::time::timeout_at(deadline, self.socket.recv(&mut buffer)).await;
                let size = match received {
                    Ok(result) => result?,
                    Err(_) => break,
                };
                let Some(response) = decode_reply(&buffer[..size], id)? else {
                    continue;
                };
                // Make reset records portable to another running world.
                if matches!(request.request, Request::Reset { .. }) {
                    request.request = Request::Reset {
                        seed: Some(response.seed),
                        scenario: Some(if response.scenario == "island-photo-v2" {
                            "island"
                        } else {
                            "legacy"
                        }),
                    };
                }
                let record = json!({"request": request, "response": response});
                serde_json::to_writer(&mut self.replay, &record)?;
                writeln!(self.replay)?;
                self.replay.flush()?;
                return Ok(response);
            }
        }
        anyhow::bail!("Simulation request {id} timed out after three attempts")
    }

    pub async fn image(observation: &Observation) -> Result<Vec<u8>> {
        let path = Path::new(
            observation
                .image
                .as_deref()
                .context("Observation has no image")?,
        );
        anyhow::ensure!(
            path.starts_with(".snapbench/observations")
                && path
                    .components()
                    .all(|part| matches!(part, Component::Normal(_))),
            "Invalid observation path"
        );
        let image = tokio::fs::read(path)
            .await
            .context("Failed to read completed observation")?;
        tokio::fs::remove_file(path).await?;
        Ok(image)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn transport_ignores_stale_replies_and_records_the_actual_reset_scenario() {
        let server = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        socket.connect(server.local_addr().unwrap()).await.unwrap();
        let path =
            std::env::temp_dir().join(format!("snapbench-transport-{}.jsonl", std::process::id()));
        let replay = std::fs::File::create(&path).unwrap();
        let mut simulator = Simulator {
            socket,
            next_id: 1,
            replay,
            replay_path: path.to_string_lossy().into(),
        };
        let server_task = tokio::spawn(async move {
            let mut buffer = [0u8; 2048];
            let (size, address) = server.recv_from(&mut buffer).await.unwrap();
            let request: serde_json::Value = serde_json::from_slice(&buffer[..size]).unwrap();
            assert_eq!(request, json!({"id":1,"op":"reset"}));
            server
                .send_to(br#"{"version":2,"id":0,"status":"stale_id"}"#, address)
                .await
                .unwrap();
            let mut observation = crate::protocol::test_observation(3);
            observation.scenario = "legacy-proximity-v1".into();
            server
                .send_to(&serde_json::to_vec(&observation).unwrap(), address)
                .await
                .unwrap();
        });
        let observation = simulator
            .request(Request::Reset {
                seed: None,
                scenario: None,
            })
            .await
            .unwrap();
        assert_eq!(observation.remaining, 3);
        server_task.await.unwrap();
        drop(simulator);
        let record: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(
            record["request"],
            json!({"id":1,"op":"reset","seed":42,"scenario":"legacy"})
        );
        std::fs::remove_file(path).unwrap();
    }
}
