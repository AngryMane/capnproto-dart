use capnp_rpc::{rpc_twoparty_capnp, twoparty, RpcSystem};
use std::rc::Rc;
use futures::AsyncReadExt;
use tokio::net::TcpListener;
use tokio::task;
use tokio_util::compat::TokioAsyncReadCompatExt;

pub mod greeter_capnp {
    include!(concat!(env!("OUT_DIR"), "/greeter_capnp.rs"));
}

use greeter_capnp::{greet_session, greeter};

// ---------------------------------------------------------------------------
// GreetSessionImpl
// ---------------------------------------------------------------------------

struct GreetSessionImpl {
    name: String,
}

impl greet_session::Server for GreetSessionImpl {
    async fn greet(
        self: Rc<Self>,
        _params: greet_session::GreetParams,
        mut results: greet_session::GreetResults,
    ) -> Result<(), capnp::Error> {
        println!("[server] session.greet() for \"{}\"", self.name);
        let reply = format!("Hello, {}! (session greeting from Rust server)", self.name);
        results.get().set_reply(reply.as_str());
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// GreeterImpl
// ---------------------------------------------------------------------------

struct GreeterImpl;

impl greeter::Server for GreeterImpl {
    async fn greet(
        self: Rc<Self>,
        params: greeter::GreetParams,
        mut results: greeter::GreetResults,
    ) -> Result<(), capnp::Error> {
        let name = params.get()?.get_name()?.to_str().unwrap_or("?").to_string();
        println!("[server] greet(\"{}\")", name);
        let reply = format!("Hello, {}! (from Rust server)", name);
        results.get().set_reply(reply.as_str());
        Ok(())
    }

    async fn new_session(
        self: Rc<Self>,
        params: greeter::NewSessionParams,
        mut results: greeter::NewSessionResults,
    ) -> Result<(), capnp::Error> {
        let name = params.get()?.get_name()?.to_str().unwrap_or("?").to_string();
        println!("[server] newSession(\"{}\")", name);
        let session: greet_session::Client =
            capnp_rpc::new_client(GreetSessionImpl { name });
        results.get().set_session(session);
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let local = task::LocalSet::new();
    local
        .run_until(async {
            let listener = TcpListener::bind("127.0.0.1:12345").await?;
            println!("[server] listening on 127.0.0.1:12345");

            loop {
                let (stream, peer) = listener.accept().await?;
                println!("[server] connection from {}", peer);
                stream.set_nodelay(true)?;

                let (reader, writer) = stream.compat().split();

                let network = twoparty::VatNetwork::new(
                    futures::io::BufReader::new(reader),
                    futures::io::BufWriter::new(writer),
                    rpc_twoparty_capnp::Side::Server,
                    Default::default(),
                );

                let greeter: greeter::Client = capnp_rpc::new_client(GreeterImpl);
                let rpc_system =
                    RpcSystem::new(Box::new(network), Some(greeter.client));
                task::spawn_local(rpc_system);
            }
        })
        .await
}
