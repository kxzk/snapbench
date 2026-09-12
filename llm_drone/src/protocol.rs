use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Action {
    Forward,
    Backward,
    Left,
    Right,
    Up,
    Down,
    RotateLeft,
    RotateRight,
    LookUp,
    LookDown,
    Wait,
    Identify,
}

#[derive(Serialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Request {
    Reset {
        #[serde(skip_serializing_if = "Option::is_none")]
        seed: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        scenario: Option<&'static str>,
    },
    Observe,
    Act {
        command: Action,
        ticks: u16,
    },
}

#[derive(Serialize)]
pub struct Envelope {
    pub id: u64,
    #[serde(flatten)]
    pub request: Request,
}

#[derive(Deserialize, Serialize)]
pub struct Observation {
    pub id: u64,
    pub version: u8,
    pub status: String,
    pub scenario: String,
    pub seed: u64,
    pub tick: u64,
    pub state_hash: String,
    pub x: f32,
    pub y: f32,
    pub z: f32,
    pub yaw: f32,
    pub pitch: f32,
    pub remaining: u8,
    pub image: Option<String>,
}

pub fn decode_reply(data: &[u8], expected_id: u64) -> Result<Option<Observation>> {
    // Rejections carry only this header. Successful replies must contain the
    // entire observation; missing fields must never become a zeroed final state.
    #[derive(Deserialize)]
    struct Header {
        id: u64,
        version: u8,
        status: String,
    }
    let header: Header = serde_json::from_slice(data).context("Invalid simulation reply")?;
    if header.id != expected_id {
        return Ok(None);
    }
    anyhow::ensure!(header.version == 2, "Unsupported simulation protocol");
    anyhow::ensure!(
        matches!(header.status.as_str(), "ok" | "identified" | "no_subject"),
        "Simulation rejected request {expected_id}: {}",
        header.status
    );
    let observation: Observation =
        serde_json::from_slice(data).context("Incomplete simulation observation")?;
    anyhow::ensure!(
        observation.remaining <= 3,
        "Invalid remaining creature count"
    );
    anyhow::ensure!(
        [
            observation.x,
            observation.y,
            observation.z,
            observation.yaw,
            observation.pitch
        ]
        .iter()
        .all(|value| value.is_finite()),
        "Invalid simulation pose"
    );
    anyhow::ensure!(
        matches!(
            observation.scenario.as_str(),
            "island-photo-v2" | "legacy-proximity-v1"
        ),
        "Unsupported simulation scenario"
    );
    Ok(Some(observation))
}

#[cfg(test)]
pub use tests::observation as test_observation;

#[cfg(test)]
mod tests {
    use super::{Action, Envelope, Request, decode_reply};
    use serde_json::json;

    pub fn observation(remaining: u8) -> super::Observation {
        serde_json::from_value(json!({
            "id": 1, "version": 2, "status": "ok", "scenario": "island-photo-v2",
            "seed": 42, "tick": 0, "state_hash": "abc", "x": 1.0, "y": 2.0,
            "z": 3.0, "yaw": 0.0, "pitch": -12.0, "remaining": remaining, "image": null
        }))
        .unwrap()
    }

    #[test]
    fn missing_success_fields_never_become_a_completed_game() {
        let complete = serde_json::to_value(observation(0)).unwrap();
        for field in [
            "scenario",
            "seed",
            "tick",
            "state_hash",
            "x",
            "y",
            "z",
            "yaw",
            "pitch",
            "remaining",
        ] {
            let mut invalid = complete.clone();
            invalid.as_object_mut().unwrap().remove(field);
            assert!(
                decode_reply(&serde_json::to_vec(&invalid).unwrap(), 1).is_err(),
                "{field}"
            );
        }
        assert!(decode_reply(&serde_json::to_vec(&observation(255)).unwrap(), 1).is_err());
    }

    #[test]
    fn stale_replies_are_ignored_and_rejections_keep_their_reason() {
        let rejection = br#"{"id":1,"version":2,"status":"id_conflict"}"#;
        assert!(decode_reply(rejection, 2).unwrap().is_none());
        assert!(
            decode_reply(rejection, 1)
                .err()
                .unwrap()
                .to_string()
                .contains("id_conflict")
        );
        let success = serde_json::to_vec(&observation(0)).unwrap();
        assert_eq!(decode_reply(&success, 1).unwrap().unwrap().remaining, 0);
    }

    #[test]
    fn typed_actions_preserve_the_wire_contract() {
        let request = Envelope {
            id: 2,
            request: Request::Act {
                command: Action::LookDown,
                ticks: 30,
            },
        };
        assert_eq!(
            serde_json::to_value(request).unwrap(),
            json!({"id":2,"op":"act","command":"look_down","ticks":30})
        );
    }
}
