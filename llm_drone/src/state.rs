use crate::protocol::{Action, Observation};

#[derive(Default)]
pub struct DroneState {
    pub x: f32,
    pub y: f32,
    pub z: f32,
    pub yaw: f32,
    pub pitch: f32,
    pub tick: u64,
    pub creatures_found: u8,
    recent_commands: Vec<Vec<Action>>,
    position_history: Vec<(f32, f32, f32)>, // track last few positions
}

impl DroneState {
    pub fn push_commands(&mut self, commands: Vec<Action>) {
        if self.recent_commands.len() >= 5 {
            self.recent_commands.remove(0);
        }
        self.recent_commands.push(commands);
    }

    pub fn record_position(&mut self) {
        if self.position_history.len() >= 5 {
            self.position_history.remove(0);
        }
        self.position_history.push((self.x, self.y, self.z));
    }

    pub fn format_history(&self) -> String {
        if self.recent_commands.is_empty() {
            return "none".into();
        }
        self.recent_commands
            .iter()
            .map(|cmds| serde_json::to_string(cmds).expect("Actions serialize as strings"))
            .collect::<Vec<_>>()
            .join(" → ")
    }

    pub fn format_position_history(&self) -> String {
        if self.position_history.len() < 2 {
            return "insufficient data".into();
        }
        self.position_history
            .iter()
            .map(|(x, y, z)| format!("({x:.1},{y:.1},{z:.1})"))
            .collect::<Vec<_>>()
            .join(" → ")
    }

    pub fn is_stuck(&self) -> bool {
        if self.position_history.len() < 3 {
            return false;
        }
        // Check if last 3 positions are nearly identical
        let recent = &self.position_history[self.position_history.len() - 3..];
        let (x0, y0, z0) = recent[2];
        recent
            .iter()
            .all(|(x, y, z)| (x - x0).abs() < 0.5 && (y - y0).abs() < 0.5 && (z - z0).abs() < 0.5)
    }

    pub fn game_over(&self) -> bool {
        self.creatures_found == 3
    }

    pub fn update(&mut self, response: &Observation) {
        self.x = response.x;
        self.y = response.y;
        self.z = response.z;
        self.yaw = response.yaw;
        self.pitch = response.pitch;
        self.tick = response.tick;
        self.creatures_found = 3 - response.remaining;
    }
}
#[cfg(test)]
mod tests {
    use super::DroneState;

    #[test]
    fn final_identification_completes_on_the_same_response() {
        let mut state = DroneState::default();
        state.update(&crate::protocol::test_observation(0));
        assert!(state.game_over());
        assert_eq!(state.creatures_found, 3);
        assert_eq!((state.x, state.y, state.z), (1.0, 2.0, 3.0));
    }
}
