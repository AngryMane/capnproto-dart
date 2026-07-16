use capnp::capability::Promise;
use capnp_rpc::{pry, rpc_twoparty_capnp, twoparty, RpcSystem};
use futures::AsyncReadExt;
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use tokio::net::TcpListener;
use tokio::sync::oneshot;
use tokio::task;
use tokio_util::compat::TokioAsyncReadCompatExt;

pub mod complex_capnp {
    include!(concat!(env!("OUT_DIR"), "/complex_capnp.rs"));
}

use complex_capnp::{
    byte_sink, byte_source, capability_factory, complex_test_service, diamond, named_union,
    observer, pipeline_target, repository,
};

// ---------------------------------------------------------------------------
// PipelineTargetImpl
// ---------------------------------------------------------------------------

struct PipelineTargetImpl {
    name: String,
}

impl pipeline_target::Server for PipelineTargetImpl {
    fn get_child(
        &mut self,
        params: pipeline_target::GetChildParams,
        mut results: pipeline_target::GetChildResults,
    ) -> Promise<(), capnp::Error> {
        let name = pry!(pry!(params.get()).get_name())
            .to_str()
            .unwrap_or("child")
            .to_string();
        println!("[server] pipeline.getChild(\"{}\")", name);
        let child: pipeline_target::Client =
            capnp_rpc::new_client(PipelineTargetImpl { name });
        results.get().set_child(child);
        Promise::ok(())
    }

    fn get_repository(
        &mut self,
        _params: pipeline_target::GetRepositoryParams,
        mut results: pipeline_target::GetRepositoryResults,
    ) -> Promise<(), capnp::Error> {
        println!("[server] pipeline[{}].getRepository()", self.name);
        let repo: repository::Client<capnp::text::Owned, complex_capnp::person::Owned> =
            capnp_rpc::new_client(RepositoryImpl::new());
        results.get().set_repository(repo);
        Promise::ok(())
    }

    fn ping(
        &mut self,
        params: pipeline_target::PingParams,
        mut results: pipeline_target::PingResults,
    ) -> Promise<(), capnp::Error> {
        let payload = pry!(pry!(params.get()).get_payload());
        println!("[server] pipeline[{}].ping({} bytes)", self.name, payload.len());
        results.get().set_payload(payload);
        Promise::ok(())
    }
}

// ---------------------------------------------------------------------------
// RepositoryImpl - HashMap<String, (Vec<capnp::Word>, u64)>
// ---------------------------------------------------------------------------

struct RepositoryImpl {
    store: Rc<RefCell<HashMap<String, (Vec<u8>, u64)>>>,
    revision: Rc<RefCell<u64>>,
}

impl RepositoryImpl {
    fn new() -> Self {
        Self {
            store: Rc::new(RefCell::new(HashMap::new())),
            revision: Rc::new(RefCell::new(0)),
        }
    }
}

impl repository::Server<capnp::text::Owned, complex_capnp::person::Owned> for RepositoryImpl {
    fn get(
        &mut self,
        params: repository::GetParams<capnp::text::Owned, complex_capnp::person::Owned>,
        mut results: repository::GetResults<capnp::text::Owned, complex_capnp::person::Owned>,
    ) -> Promise<(), capnp::Error> {
        let key = pry!(pry!(pry!(params.get()).get_key()).to_str().map_err(|e| {
            capnp::Error::failed(format!("invalid key utf8: {}", e))
        }))
        .to_string();
        let store = self.store.borrow();
        let mut r = results.get();
        if let Some((bytes, rev)) = store.get(&key) {
            r.set_revision(*rev);
            // Deserialize and set person into result.some
            let msg = pry!(capnp::serialize::read_message_from_flat_slice(
                &mut &bytes[..],
                Default::default()
            ));
            let person: complex_capnp::person::Reader =
                pry!(msg.get_root::<complex_capnp::person::Reader>());
            let mut opt = pry!(r.get_result());
            pry!(opt.set_some(person));
        } else {
            r.set_revision(0);
            let mut opt = pry!(r.get_result());
            opt.set_none(());
        }
        Promise::ok(())
    }

    fn put(
        &mut self,
        params: repository::PutParams<capnp::text::Owned, complex_capnp::person::Owned>,
        mut results: repository::PutResults<capnp::text::Owned, complex_capnp::person::Owned>,
    ) -> Promise<(), capnp::Error> {
        let p = pry!(params.get());
        let key = pry!(pry!(p.get_key()).to_str().map_err(|e| {
            capnp::Error::failed(format!("invalid key utf8: {}", e))
        }))
        .to_string();
        let person_reader = pry!(p.get_value());

        // Serialize person to words
        let mut msg = capnp::message::Builder::new_default();
        pry!(msg.set_root(person_reader));
        let words = capnp::serialize::write_message_to_words(&msg);

        let mut store = self.store.borrow_mut();
        let mut rev_cell = self.revision.borrow_mut();
        *rev_cell += 1;
        let new_rev = *rev_cell;

        let mut r = results.get();
        r.set_new_revision(new_rev);

        if let Some((old_bytes, _old_rev)) = store.get(&key) {
            // Set previous to Some(old_person)
            let old_msg = pry!(capnp::serialize::read_message_from_flat_slice(
                &mut &old_bytes[..],
                Default::default()
            ));
            let old_person: complex_capnp::person::Reader =
                pry!(old_msg.get_root::<complex_capnp::person::Reader>());
            let mut prev = pry!(r.get_previous());
            pry!(prev.set_some(old_person));
        } else {
            let mut prev = pry!(r.get_previous());
            prev.set_none(());
        }

        store.insert(key, (words, new_rev));
        Promise::ok(())
    }

    fn remove(
        &mut self,
        params: repository::RemoveParams<capnp::text::Owned, complex_capnp::person::Owned>,
        mut results: repository::RemoveResults<capnp::text::Owned, complex_capnp::person::Owned>,
    ) -> Promise<(), capnp::Error> {
        let key = pry!(pry!(pry!(params.get()).get_key()).to_str().map_err(|e| {
            capnp::Error::failed(format!("invalid key utf8: {}", e))
        }))
        .to_string();

        let mut store = self.store.borrow_mut();
        let mut rev_cell = self.revision.borrow_mut();
        *rev_cell += 1;
        let new_rev = *rev_cell;

        let mut r = results.get();
        r.set_new_revision(new_rev);

        if let Some((old_bytes, _)) = store.remove(&key) {
            let old_msg = pry!(capnp::serialize::read_message_from_flat_slice(
                &mut &old_bytes[..],
                Default::default()
            ));
            let old_person: complex_capnp::person::Reader =
                pry!(old_msg.get_root::<complex_capnp::person::Reader>());
            let mut removed = pry!(r.get_removed());
            pry!(removed.set_some(old_person));
        } else {
            let mut removed = pry!(r.get_removed());
            removed.set_none(());
        }

        Promise::ok(())
    }

    fn list(
        &mut self,
        _params: repository::ListParams<capnp::text::Owned, complex_capnp::person::Owned>,
        mut results: repository::ListResults<capnp::text::Owned, complex_capnp::person::Owned>,
    ) -> Promise<(), capnp::Error> {
        let store = self.store.borrow();
        let entries_count = store.len() as u32;
        let mut entries = results.get().init_entries(entries_count);

        for (i, (key, (bytes, _rev))) in store.iter().enumerate() {
            let mut kv = entries.reborrow().get(i as u32);
            pry!(kv.set_key(key.as_str()));

            let msg = pry!(capnp::serialize::read_message_from_flat_slice(
                &mut &bytes[..],
                Default::default()
            ));
            let person: complex_capnp::person::Reader =
                pry!(msg.get_root::<complex_capnp::person::Reader>());
            pry!(kv.set_value(person));
        }

        Promise::ok(())
    }

    fn open_cursor(
        &mut self,
        _params: repository::OpenCursorParams<capnp::text::Owned, complex_capnp::person::Owned>,
        _results: repository::OpenCursorResults<capnp::text::Owned, complex_capnp::person::Owned>,
    ) -> Promise<(), capnp::Error> {
        Promise::err(capnp::Error::failed("openCursor: not implemented".to_string()))
    }

    fn watch(
        &mut self,
        _params: repository::WatchParams<capnp::text::Owned, complex_capnp::person::Owned>,
        _results: repository::WatchResults<capnp::text::Owned, complex_capnp::person::Owned>,
    ) -> Promise<(), capnp::Error> {
        Promise::err(capnp::Error::failed("watch: not implemented".to_string()))
    }
}

// ---------------------------------------------------------------------------
// ByteSinkImpl
// ---------------------------------------------------------------------------

struct ByteSinkImpl {
    data: Rc<RefCell<Vec<u8>>>,
}

impl ByteSinkImpl {
    fn new() -> Self {
        Self {
            data: Rc::new(RefCell::new(Vec::new())),
        }
    }
}

impl byte_sink::Server for ByteSinkImpl {
    fn write(
        &mut self,
        params: byte_sink::WriteParams,
    ) -> Promise<(), capnp::Error> {
        let chunk = pry!(pry!(params.get()).get_chunk());
        self.data.borrow_mut().extend_from_slice(chunk);
        Promise::ok(())
    }

    fn finish(
        &mut self,
        _params: byte_sink::FinishParams,
        mut results: byte_sink::FinishResults,
    ) -> Promise<(), capnp::Error> {
        let data = self.data.borrow();
        let byte_count = data.len() as u64;
        let checksum: u8 = data.iter().fold(0u8, |acc, &b| acc ^ b);
        let mut r = results.get();
        r.set_byte_count(byte_count);
        r.set_checksum(&[checksum]);
        Promise::ok(())
    }

    fn abort(
        &mut self,
        _params: byte_sink::AbortParams,
        _results: byte_sink::AbortResults,
    ) -> Promise<(), capnp::Error> {
        self.data.borrow_mut().clear();
        Promise::ok(())
    }
}

// ---------------------------------------------------------------------------
// ByteSourceImpl
// ---------------------------------------------------------------------------

struct ByteSourceImpl {
    data: Vec<u8>,
}

impl ByteSourceImpl {
    fn new(data: Vec<u8>) -> Self {
        Self { data }
    }
}

impl byte_source::Server for ByteSourceImpl {
    fn pump_to(
        &mut self,
        params: byte_source::PumpToParams,
        mut results: byte_source::PumpToResults,
    ) -> Promise<(), capnp::Error> {
        let p = pry!(params.get());
        let sink = pry!(p.get_sink());
        let chunk_size = p.get_chunk_size() as usize;
        let chunk_size = if chunk_size == 0 { 65536 } else { chunk_size };
        let data = self.data.clone();

        Promise::from_future(async move {
            let mut offset = 0;
            let total = data.len();
            while offset < total {
                let end = std::cmp::min(offset + chunk_size, total);
                let chunk = &data[offset..end];
                let mut req = sink.write_request();
                req.get().set_chunk(chunk);
                req.send().await?;
                offset = end;
            }
            let finish_resp = sink.finish_request().send().promise.await?;
            let byte_count = finish_resp.get()?.get_byte_count();
            results.get().set_byte_count(byte_count);
            Ok(())
        })
    }
}

// ---------------------------------------------------------------------------
// CapabilityFactoryImpl
// ---------------------------------------------------------------------------

struct CapabilityFactoryImpl;

impl capability_factory::Server for CapabilityFactoryImpl {
    // All methods return "not implemented" - generic methods aren't easily supported
}

// ---------------------------------------------------------------------------
// ComplexTestServiceImpl
// ---------------------------------------------------------------------------

struct ComplexTestServiceImpl {
    shutdown_tx: Option<oneshot::Sender<()>>,
}

impl complex_test_service::Server for ComplexTestServiceImpl {
    fn echo(
        &mut self,
        params: complex_test_service::EchoParams,
        mut results: complex_test_service::EchoResults,
    ) -> Promise<(), capnp::Error> {
        let _req = pry!(pry!(params.get()).get_request());
        let mut resp = results.get().init_response();
        resp.set_accepted(true);
        resp.set_status(complex_capnp::Status::Running);
        resp.set_message("echo from Rust");
        Promise::ok(())
    }

    fn echo_scalars(
        &mut self,
        params: complex_test_service::EchoScalarsParams,
        mut results: complex_test_service::EchoScalarsResults,
    ) -> Promise<(), capnp::Error> {
        let p = pry!(params.get());
        let value = pry!(p.get_value());
        println!("[server] echoScalars(boolean={})", value.get_boolean());
        pry!(results.get().set_value(value));
        Promise::ok(())
    }

    fn echo_lists(
        &mut self,
        params: complex_test_service::EchoListsParams,
        mut results: complex_test_service::EchoListsResults,
    ) -> Promise<(), capnp::Error> {
        let p = pry!(params.get());
        let value = pry!(p.get_value());
        let text_count = value.get_texts().map(|l| l.len()).unwrap_or(0);
        println!("[server] echoLists(texts.len={})", text_count);
        pry!(results.get().set_value(value));
        Promise::ok(())
    }

    fn echo_union(
        &mut self,
        params: complex_test_service::EchoUnionParams,
        mut results: complex_test_service::EchoUnionResults,
    ) -> Promise<(), capnp::Error> {
        let p = pry!(params.get());
        let value = pry!(p.get_value());
        let which = value.get_payload().which();
        let variant = match &which {
            Ok(named_union::payload::Which::Empty(())) => "empty",
            Ok(named_union::payload::Which::Scalar(_)) => "scalar",
            Ok(named_union::payload::Which::Text(_)) => "text",
            Ok(named_union::payload::Which::Data(_)) => "data",
            Ok(named_union::payload::Which::Person(_)) => "person",
            Ok(named_union::payload::Which::Coordinates(_)) => "coordinates",
            Ok(named_union::payload::Which::Rectangle(_)) => "rectangle",
            Err(_) => "unknown",
        };
        println!("[server] echoUnion(payload={})", variant);
        pry!(results.get().set_value(value));
        Promise::ok(())
    }

    fn echo_any_pointer(
        &mut self,
        _params: complex_test_service::EchoAnyPointerParams,
        _results: complex_test_service::EchoAnyPointerResults,
    ) -> Promise<(), capnp::Error> {
        Promise::err(capnp::Error::failed(
            "echoAnyPointer: generic methods not supported at runtime".to_string(),
        ))
    }

    fn exchange_capabilities(
        &mut self,
        _params: complex_test_service::ExchangeCapabilitiesParams,
        _results: complex_test_service::ExchangeCapabilitiesResults,
    ) -> Promise<(), capnp::Error> {
        Promise::err(capnp::Error::failed(
            "exchangeCapabilities: not implemented".to_string(),
        ))
    }

    fn call_observer(
        &mut self,
        params: complex_test_service::CallObserverParams,
        mut results: complex_test_service::CallObserverResults,
    ) -> Promise<(), capnp::Error> {
        let p = pry!(params.get());
        let observer: observer::Client<complex_capnp::person::Owned> = pry!(p.get_observer());
        let events = pry!(p.get_events());
        let event_count = events.len();

        println!("[server] callObserver(events={})", event_count);

        Promise::from_future(async move {
            for seq in 0..event_count {
                let mut req = observer.on_next_request();
                req.get().set_sequence(seq as u64);
                req.send().promise.await?;
            }
            observer.on_complete_request().send().promise.await?;
            results.get().set_delivered(event_count);
            Ok(())
        })
    }

    fn make_pipeline(
        &mut self,
        params: complex_test_service::MakePipelineParams,
        mut results: complex_test_service::MakePipelineResults,
    ) -> Promise<(), capnp::Error> {
        let depth = pry!(params.get()).get_depth();
        println!("[server] makePipeline(depth={})", depth);
        let target: pipeline_target::Client = capnp_rpc::new_client(PipelineTargetImpl {
            name: format!("root(depth={})", depth),
        });
        results.get().set_target(target);
        Promise::ok(())
    }

    fn open_upload(
        &mut self,
        _params: complex_test_service::OpenUploadParams,
        mut results: complex_test_service::OpenUploadResults,
    ) -> Promise<(), capnp::Error> {
        println!("[server] openUpload()");
        let sink: byte_sink::Client = capnp_rpc::new_client(ByteSinkImpl::new());
        results.get().set_sink(sink);
        Promise::ok(())
    }

    fn open_download(
        &mut self,
        params: complex_test_service::OpenDownloadParams,
        mut results: complex_test_service::OpenDownloadResults,
    ) -> Promise<(), capnp::Error> {
        let p = pry!(params.get());
        let resource_id = pry!(p.get_resource_id());
        // Use the text value of the identifier as the data to serve
        let data: Vec<u8> = match resource_id.which() {
            Ok(complex_capnp::identifier::Which::Textual(t)) => {
                t.unwrap_or(capnp::text::Reader::from("")).as_bytes().to_vec()
            }
            Ok(complex_capnp::identifier::Which::Binary(d)) => {
                d.unwrap_or(&[]).to_vec()
            }
            _ => b"default-data".to_vec(),
        };
        println!("[server] openDownload({} bytes)", data.len());
        let source: byte_source::Client = capnp_rpc::new_client(ByteSourceImpl::new(data));
        results.get().set_source(source);
        Promise::ok(())
    }

    fn get_repository(
        &mut self,
        _params: complex_test_service::GetRepositoryParams,
        mut results: complex_test_service::GetRepositoryResults,
    ) -> Promise<(), capnp::Error> {
        println!("[server] getRepository()");
        let repo: repository::Client<capnp::text::Owned, complex_capnp::person::Owned> =
            capnp_rpc::new_client(RepositoryImpl::new());
        results.get().set_repository(repo);
        Promise::ok(())
    }

    fn get_factory(
        &mut self,
        _params: complex_test_service::GetFactoryParams,
        mut results: complex_test_service::GetFactoryResults,
    ) -> Promise<(), capnp::Error> {
        println!("[server] getFactory()");
        let factory: capability_factory::Client = capnp_rpc::new_client(CapabilityFactoryImpl);
        results.get().set_factory(factory);
        Promise::ok(())
    }

    fn use_diamond(
        &mut self,
        params: complex_test_service::UseDiamondParams,
        mut results: complex_test_service::UseDiamondResults,
    ) -> Promise<(), capnp::Error> {
        let p = pry!(params.get());
        let diamond: diamond::Client = pry!(p.get_diamond());
        let value = p.get_value();
        println!("[server] useDiamond(value={})", value);

        Promise::from_future(async move {
            let mut req = diamond.both_request();
            {
                let mut b = req.get();
                b.set_left_value(value);
                b.set_right_value(value);
            }
            let resp = req.send().promise.await?;
            let sum = resp.get()?.get_sum();
            results.get().set_result(sum);
            Ok(())
        })
    }

    fn fail_intentionally(
        &mut self,
        params: complex_test_service::FailIntentionallyParams,
        _results: complex_test_service::FailIntentionallyResults,
    ) -> Promise<(), capnp::Error> {
        let p = pry!(params.get());
        let code = p.get_code();
        let message = pry!(p.get_message()).to_str().unwrap_or("").to_string();
        println!("[server] failIntentionally(code={}, message=\"{}\")", code, message);
        Promise::err(capnp::Error::failed(format!(
            "[code={}] {}",
            code, message
        )))
    }

    fn shutdown(
        &mut self,
        _params: complex_test_service::ShutdownParams,
        _results: complex_test_service::ShutdownResults,
    ) -> Promise<(), capnp::Error> {
        println!("[server] shutdown requested");
        if let Some(tx) = self.shutdown_tx.take() {
            let _ = tx.send(());
        }
        Promise::ok(())
    }

    fn probe_pipeline_target(
        &mut self,
        params: complex_test_service::ProbePipelineTargetParams,
        mut results: complex_test_service::ProbePipelineTargetResults,
    ) -> Promise<(), capnp::Error> {
        let p = pry!(params.get());
        let target: pipeline_target::Client = pry!(p.get_target());
        let payload = pry!(p.get_payload()).to_vec();
        println!("[server] probePipelineTarget({} bytes)", payload.len());

        Promise::from_future(async move {
            let mut req = target.ping_request();
            req.get().set_payload(&payload);
            let resp = req.send().promise.await?;
            let echoed = resp.get()?.get_payload()?;
            results.get().set_payload(echoed);
            Ok(())
        })
    }

    fn make_promised_pipeline(
        &mut self,
        params: complex_test_service::MakePromisedPipelineParams,
        mut results: complex_test_service::MakePromisedPipelineResults,
    ) -> Promise<(), capnp::Error> {
        let delay_ms = pry!(params.get()).get_delay_ms();
        println!("[server] makePromisedPipeline(delayMs={})", delay_ms);
        let target: pipeline_target::Client = capnp_rpc::new_future_client(async move {
            tokio::time::sleep(std::time::Duration::from_millis(delay_ms as u64)).await;
            Ok(capnp_rpc::new_client(PipelineTargetImpl {
                name: format!("promised(delay={})", delay_ms),
            }))
        });
        results.get().set_target(target);
        Promise::ok(())
    }

    fn echo_pipeline_target_later(
        &mut self,
        params: complex_test_service::EchoPipelineTargetLaterParams,
        mut results: complex_test_service::EchoPipelineTargetLaterResults,
    ) -> Promise<(), capnp::Error> {
        let p = pry!(params.get());
        let target: pipeline_target::Client = pry!(p.get_target());
        let delay_ms = p.get_delay_ms();
        println!("[server] echoPipelineTargetLater(delayMs={})", delay_ms);
        let promised: pipeline_target::Client = capnp_rpc::new_future_client(async move {
            tokio::time::sleep(std::time::Duration::from_millis(delay_ms as u64)).await;
            Ok(target)
        });
        results.get().set_target(promised);
        Promise::ok(())
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
            let listener = TcpListener::bind("127.0.0.1:12346").await?;
            println!("[server] listening on 127.0.0.1:12346");

            let (shutdown_tx, mut shutdown_rx) = oneshot::channel::<()>();
            let shutdown_tx = std::cell::RefCell::new(Some(shutdown_tx));

            loop {
                tokio::select! {
                    accept = listener.accept() => {
                        let (stream, peer) = accept?;
                        println!("[server] connection from {}", peer);
                        stream.set_nodelay(true)?;

                        let (reader, writer) = stream.compat().split();
                        let network = twoparty::VatNetwork::new(
                            futures::io::BufReader::new(reader),
                            futures::io::BufWriter::new(writer),
                            rpc_twoparty_capnp::Side::Server,
                            Default::default(),
                        );

                        let tx = shutdown_tx.borrow_mut().take();
                        let svc: complex_test_service::Client =
                            capnp_rpc::new_client(ComplexTestServiceImpl {
                                shutdown_tx: tx,
                            });
                        let rpc_system = RpcSystem::new(Box::new(network), Some(svc.client));
                        task::spawn_local(rpc_system);
                    }
                    _ = &mut shutdown_rx => {
                        println!("[server] shutdown complete");
                        break;
                    }
                }
            }
            Ok(())
        })
        .await
}
