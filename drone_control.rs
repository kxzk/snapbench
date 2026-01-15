use std::net::UdpSocket;
use std::time::Duration;

const ADDR: &str = "127.0.0.1:9999";
const TIMEOUT: Duration = Duration::from_secs(1);

#[derive(Debug, Default)]
struct DroneState {
    x: f32,
    y: f32,
    z: f32,
    yaw: f32,
}

impl DroneState {
    fn from_response(response: &str) -> Self {
        let mut state = Self::default();
        for part in response.split_whitespace() {
            if let Some((key, val)) = part.split_once('=') {
                if let Ok(v) = val.parse::<f32>() {
                    match key {
                        "x" => state.x = v,
                        "y" => state.y = v,
                        "z" => state.z = v,
                        "yaw" => state.yaw = v,
                        _ => {}
                    }
                }
            }
        }
        state
    }
}

fn send_command(socket: &UdpSocket, cmd: &str) -> String {
    let msg = format!("{cmd}\n");
    if socket.send(msg.as_bytes()).is_err() {
        return "SEND_ERROR".into();
    }

    let mut buf = [0u8; 256];
    match socket.recv(&mut buf) {
        Ok(n) => String::from_utf8_lossy(&buf[..n]).trim().to_string(),
        Err(_) => "TIMEOUT".into(),
    }
}

fn print_header() {
    println!();
    println!("███████╗███╗   ██╗ █████╗ ██████╗ ██████╗ ███████╗███╗   ██╗ ██████╗██╗  ██╗");
    println!("██╔════╝████╗  ██║██╔══██╗██╔══██╗██╔══██╗██╔════╝████╗  ██║██╔════╝██║  ██║");
    println!("███████╗██╔██╗ ██║███████║██████╔╝██████╔╝█████╗  ██╔██╗ ██║██║     ███████║");
    println!("╚════██║██║╚██╗██║██╔══██║██╔═══╝ ██╔══██╗██╔══╝  ██║╚██╗██║██║     ██╔══██║");
    println!("███████║██║ ╚████║██║  ██║██║     ██████╔╝███████╗██║ ╚████║╚██████╗██║  ██║");
    println!("╚══════╝╚═╝  ╚═══╝╚═╝  ╚═╝╚═╝     ╚═════╝ ╚══════╝╚═╝  ╚═══╝ ╚═════╝╚═╝  ╚═╝");
    println!();
    println!();
    println!("TARGET: {}   PROTOCOL: UDP   STATUS: ONLINE", ADDR);
    println!();
}

fn main() {
    let socket = UdpSocket::bind("0.0.0.0:0").expect("failed to bind socket");
    socket.connect(ADDR).expect("failed to connect");
    socket
        .set_read_timeout(Some(TIMEOUT))
        .expect("failed to set timeout");

    let commands = [
        "forward",
        "forward",
        "forward",
        "right",
        "right",
        "up",
        "rotate_right",
        "rotate_right",
        "backward",
        "identify",
    ];

    print_header();

    for cmd in commands {
        let response = send_command(&socket, cmd);

        if response.starts_with("OK") {
            let state = DroneState::from_response(&response);
            println!(
                "{:<15} OK    x={:.1} y={:.1} z={:.1} yaw={:.1}",
                cmd, state.x, state.y, state.z, state.yaw
            );
        } else {
            println!("{:<15} {}", cmd, response);
        }

        std::thread::sleep(Duration::from_secs(1));
    }

    println!();
    println!("Testing invalid command...");
    let response = send_command(&socket, "invalid_cmd");
    println!("{:<15} {}", "invalid_cmd", response);
}
