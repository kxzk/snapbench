use anyhow::Result;
use serde::Serialize;
use std::path::Path;

#[derive(Serialize, Default)]
pub struct BenchMetrics {
    pub model: String,
    pub scenario: String,
    pub simulation_ticks: u64,
    pub replay_path: String,
    pub status: String,
    pub iterations: u32,
    pub movements: u32,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub creatures_found: u8,
    pub creature_times_ms: Vec<u64>,
    pub total_ms: u64,
    pub failed_identifies: u32,
    pub stuck_events: u32,
    pub api_latencies_ms: Vec<u64>,
    pub api_errors: u32,
}

impl BenchMetrics {
    pub async fn save_checkpoint(&self, path: &Path) -> Result<()> {
        // Publish a complete snapshot. A timeout during the write leaves the
        // previous checkpoint readable by the benchmark runner.
        let temporary = path.with_extension("json.tmp");
        tokio::fs::write(&temporary, serde_json::to_vec(self)?).await?;
        tokio::fs::rename(&temporary, path).await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::BenchMetrics;

    #[tokio::test]
    async fn checkpoint_replacement_keeps_the_previous_snapshot_on_failure() {
        let directory =
            std::env::temp_dir().join(format!("snapbench-checkpoint-{}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("checkpoint.json");
        let mut metrics = BenchMetrics {
            input_tokens: 10,
            ..Default::default()
        };
        metrics.save_checkpoint(&path).await.unwrap();
        let original = std::fs::read(&path).unwrap();
        let temporary = path.with_extension("json.tmp");
        std::fs::create_dir(&temporary).unwrap();
        metrics.input_tokens = 20;
        assert!(metrics.save_checkpoint(&path).await.is_err());
        assert_eq!(std::fs::read(&path).unwrap(), original);
        std::fs::remove_dir(&temporary).unwrap();
        metrics.save_checkpoint(&path).await.unwrap();
        let replaced: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(replaced["input_tokens"], 20);
        assert!(!temporary.exists());
        std::fs::remove_dir_all(directory).unwrap();
    }
}
