// Golden-vector driver (rust). Usage: cargo run --offline -- <golden.vec>; includes generated src/es/chain.rs.
#[path = "es/chain.rs"]
mod chain;
use std::fs;

fn main() {
    let path = std::env::args().nth(1).expect("vec path");
    let text = fs::read_to_string(path).expect("read vec");
    let mut c: Vec<chain::Entry> = Vec::new();
    for raw in text.split('\n') {
        if raw.is_empty() || raw.starts_with('#') { continue; }
        let p: Vec<&str> = raw.split('|').collect();
        if let Some(name) = raw.strip_prefix("case ") { c = Vec::new(); println!("case {name}"); }
        else if p[0] == "pending" || p[0] == "outcome" || p[0] == "seal" {
            let r = match p[0] {
                "pending" => chain::append_pending(&mut c, p[1], p[2], p[3]),
                "outcome" => chain::append_outcome(&mut c, p[1], p[2], p[3], p[4]),
                _ => chain::seal(&mut c, p[1], p[2], p[3]),
            };
            match r { Ok(()) => println!("ok {}", c.last().unwrap().hash), Err(_) => println!("err") }
        } else if p[0] == "forge" {
            let i: i64 = p[6].parse().unwrap();
            let mut e = chain::Entry { entry_id: p[1].into(), parent_hash: c.last().map(|x| x.hash.clone()).unwrap_or_else(|| chain::GENESIS.into()), phase: p[2].into(), standing: p[3].into(), subject: p[4].into(), action: p[5].into(), pending_ref: if i >= 0 { c[i as usize].hash.clone() } else { String::new() }, hash: String::new(), seal: false };
            e.hash = chain::digest(&chain::canonical(&e).unwrap()).unwrap();
            println!("ok {}", e.hash);
            c.push(e);
        } else if p[0] == "unpaired" { println!("unpaired {}", chain::unpaired(&c).join(",")); }
        else if p[0] == "verify" { println!("verify {}", chain::verify(&c)); }
        else if p[0] == "tamper" { c[0].subject = "tampered".into(); println!("tampered"); }
    }
}
