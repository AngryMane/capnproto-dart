use capnp_rpc::{rpc_twoparty_capnp, twoparty, RpcSystem};
use futures::AsyncReadExt;
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use tokio::net::TcpListener;
use tokio::sync::oneshot;
use tokio::task;
use tokio_util::compat::TokioAsyncReadCompatExt;

// The schema's diamond interface inheritance (Diamond extends Left, Right;
// Left/Right both extend Parent) makes capnp's Rust codegen emit a
// dispatch_call_internal match arm for Parent's method IDs once per
// inheritance path, so the second occurrence is an unreachable duplicate.
// This is inherent to how the codegen handles diamond inheritance, not
// something our schema or generator can avoid — silence it here rather than
// deny warnings crate/job-wide.
#[allow(unreachable_patterns)]
pub mod complex_capnp {
    include!(concat!(env!("OUT_DIR"), "/complex_capnp.rs"));
}

use complex_capnp::{
    byte_sink, byte_source, capability_factory, complex_test_service, cursor, diamond,
    named_union, observer, pipeline_target, read_write, readable, repository, subscription,
    writable,
};

// ---------------------------------------------------------------------------
// PipelineTargetImpl
// ---------------------------------------------------------------------------

struct PipelineTargetImpl {
    name: String,
}

impl pipeline_target::Server for PipelineTargetImpl {
    async fn get_child(
        self: Rc<Self>,
        params: pipeline_target::GetChildParams,
        mut results: pipeline_target::GetChildResults,
    ) -> Result<(), capnp::Error> {
        let name = params.get()?.get_name()?.to_str().unwrap_or("child").to_string();
        println!("[server] pipeline.getChild(\"{}\")", name);
        let child: pipeline_target::Client = capnp_rpc::new_client(PipelineTargetImpl { name });
        results.get().set_child(child);
        Ok(())
    }

    async fn get_repository(
        self: Rc<Self>,
        _params: pipeline_target::GetRepositoryParams,
        mut results: pipeline_target::GetRepositoryResults,
    ) -> Result<(), capnp::Error> {
        println!("[server] pipeline[{}].getRepository()", self.name);
        let repo: repository::Client<capnp::text::Owned, complex_capnp::person::Owned> =
            capnp_rpc::new_client(RepositoryImpl::new());
        results.get().set_repository(repo);
        Ok(())
    }

    async fn ping(
        self: Rc<Self>,
        params: pipeline_target::PingParams,
        mut results: pipeline_target::PingResults,
    ) -> Result<(), capnp::Error> {
        let payload = params.get()?.get_payload()?;
        println!(
            "[server] pipeline[{}].ping({} bytes)",
            self.name,
            payload.len()
        );
        results.get().set_payload(payload);
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// RepositoryImpl - HashMap<String, (Vec<u8>, u64)>
// ---------------------------------------------------------------------------

type TextPersonChangeObserver =
    observer::Client<repository::change::Owned<capnp::text::Owned, complex_capnp::person::Owned>>;

struct RepositoryImpl {
    store: Rc<RefCell<HashMap<String, (Vec<u8>, u64)>>>,
    revision: Rc<RefCell<u64>>,
    // watch() subscribers, keyed by the id handed out to their Subscription —
    // SubscriptionImpl::cancel removes its own entry by that id. put/remove
    // notify every entry here after each change.
    subscribers: Rc<RefCell<HashMap<u64, TextPersonChangeObserver>>>,
    next_subscription_id: Rc<RefCell<u64>>,
}

impl RepositoryImpl {
    fn new() -> Self {
        Self {
            store: Rc::new(RefCell::new(HashMap::new())),
            revision: Rc::new(RefCell::new(0)),
            subscribers: Rc::new(RefCell::new(HashMap::new())),
            next_subscription_id: Rc::new(RefCell::new(0)),
        }
    }
}

/// One `put`/`remove` change, in a form independent of the wire `Change`
/// struct's union encoding — built by the caller, then translated into the
/// actual `repository::change::Builder` by [notify_text_person_subscribers].
enum TextPersonChangeKind {
    Inserted(Vec<u8>),
    Updated { new: Vec<u8>, previous: Vec<u8> },
    Removed { previous: Vec<u8> },
}

/// Decodes a serialized flat-message `Person` (as stored in
/// `RepositoryImpl::store`) and writes it into `target`.
fn set_person_from_bytes(
    mut target: complex_capnp::person::Builder<'_>,
    bytes: &[u8],
) -> Result<(), capnp::Error> {
    let msg =
        capnp::serialize::read_message_from_flat_slice(&mut &bytes[..], Default::default())?;
    let person: complex_capnp::person::Reader = msg.get_root::<complex_capnp::person::Reader>()?;
    target.set_name(person.get_name()?);
    target.set_email(person.get_email()?);
    target.set_status(person.get_status()?);
    Ok(())
}

/// Notifies every current `watch()` subscriber of `key`'s `change`, in
/// `revision` order — awaited inline from `put`/`remove` so that by the time
/// the RPC call that made the change returns, every subscriber's `onNext`
/// has already been delivered (simpler for callers/tests to reason about
/// than a fire-and-forget notification whose delivery is unordered relative
/// to the call's own Return).
async fn notify_text_person_subscribers(
    subscribers: &Rc<RefCell<HashMap<u64, TextPersonChangeObserver>>>,
    key: &str,
    revision: u64,
    change: TextPersonChangeKind,
) {
    // Snapshot first: a subscriber's own on_next handler could itself call
    // back into cancel() (dropping an entry from `subscribers`), which must
    // not invalidate this iteration.
    let observers: Vec<TextPersonChangeObserver> =
        subscribers.borrow().values().cloned().collect();
    for observer in observers {
        let mut request = observer.on_next_request();
        {
            let mut b = request.get();
            b.set_sequence(revision);
            let mut event = b.init_event();
            if let Err(e) = event.set_key(key) {
                eprintln!("[server] watch notify: failed to set key: {}", e);
                continue;
            }
            event.set_revision(revision);
            // .reborrow() before every self-consuming init_*() call below: `event`
            // (this Change builder) is still needed for the *next* field after
            // each of those, so each one only gets a short-lived reborrowed
            // handle rather than being consumed outright.
            let result: Result<(), capnp::Error> = match &change {
                TextPersonChangeKind::Inserted(bytes) => {
                    let r = set_person_from_bytes(event.reborrow().init_inserted(), bytes);
                    event.reborrow().init_previous_value().set_none(());
                    r
                }
                TextPersonChangeKind::Updated { new, previous } => {
                    let r = set_person_from_bytes(event.reborrow().init_updated(), new);
                    let prev_result = set_person_from_bytes(
                        event.reborrow().init_previous_value().init_some(),
                        previous,
                    );
                    r.and(prev_result)
                }
                TextPersonChangeKind::Removed { previous } => {
                    event.set_removed(());
                    set_person_from_bytes(
                        event.reborrow().init_previous_value().init_some(),
                        previous,
                    )
                }
            };
            if let Err(e) = result {
                eprintln!("[server] watch notify: failed to encode change: {}", e);
                continue;
            }
        }
        if let Err(e) = request.send().promise.await {
            eprintln!("[server] watch notify: onNext failed: {}", e);
        }
    }
}

struct SubscriptionImpl {
    subscribers: Rc<RefCell<HashMap<u64, TextPersonChangeObserver>>>,
    id: u64,
}

impl subscription::Server for SubscriptionImpl {
    async fn cancel(
        self: Rc<Self>,
        _params: subscription::CancelParams,
        mut results: subscription::CancelResults,
    ) -> Result<(), capnp::Error> {
        let was_active = self.subscribers.borrow_mut().remove(&self.id).is_some();
        results.get().set_was_active(was_active);
        Ok(())
    }

    async fn get_id(
        self: Rc<Self>,
        _params: subscription::GetIdParams,
        mut results: subscription::GetIdResults,
    ) -> Result<(), capnp::Error> {
        results.get().set_id(self.id);
        Ok(())
    }
}

struct TextPersonCursorImpl {
    // A snapshot taken at openCursor() time, in unspecified order (`store`
    // is a HashMap, so `.iter()`'s order is not insertion order) — later
    // put()/remove() calls do not affect an already-open cursor.
    entries: RefCell<std::vec::IntoIter<(String, Vec<u8>)>>,
}

impl cursor::Server<complex_capnp::key_value::Owned<capnp::text::Owned, complex_capnp::person::Owned>>
    for TextPersonCursorImpl
{
    async fn next(
        self: Rc<Self>,
        _params: cursor::NextParams<
            complex_capnp::key_value::Owned<capnp::text::Owned, complex_capnp::person::Owned>,
        >,
        mut results: cursor::NextResults<
            complex_capnp::key_value::Owned<capnp::text::Owned, complex_capnp::person::Owned>,
        >,
    ) -> Result<(), capnp::Error> {
        let next_entry = self.entries.borrow_mut().next();
        let mut result = results.get().init_result();
        match next_entry {
            None => result.set_done(()),
            Some((key, bytes)) => {
                let mut kv = result.init_value();
                kv.set_key(key.as_str())?;
                set_person_from_bytes(kv.init_value(), &bytes)?;
            }
        }
        Ok(())
    }
}

fn serialize_any_pointer(reader: capnp::any_pointer::Reader) -> capnp::Result<Vec<u8>> {
    let mut msg = capnp::message::Builder::new_default();
    let mut root: capnp::any_pointer::Builder = msg.init_root();
    root.set_as::<capnp::any_pointer::Owned>(reader)?;
    Ok(capnp::serialize::write_message_to_words(&msg))
}

struct GenericCellImpl {
    value: Rc<RefCell<Option<Vec<u8>>>>,
    revision: Rc<RefCell<u64>>,
}

impl GenericCellImpl {
    fn new(initial_value: Option<Vec<u8>>) -> Self {
        Self {
            value: Rc::new(RefCell::new(initial_value)),
            revision: Rc::new(RefCell::new(1)),
        }
    }
}

impl readable::Server<capnp::any_pointer::Owned> for GenericCellImpl {
    async fn read(
        self: Rc<Self>,
        _params: readable::ReadParams<capnp::any_pointer::Owned>,
        mut results: readable::ReadResults<capnp::any_pointer::Owned>,
    ) -> Result<(), capnp::Error> {
        let mut r = results.get();
        r.set_revision(*self.revision.borrow());
        if let Some(bytes) = self.value.borrow().as_ref() {
            let msg = capnp::serialize::read_message_from_flat_slice(
                &mut &bytes[..],
                Default::default(),
            )?;
            let value: capnp::any_pointer::Reader =
                msg.get_root::<capnp::any_pointer::Reader>()?;
            r.set_value(value)?;
        }
        Ok(())
    }
}

impl writable::Server<capnp::any_pointer::Owned> for GenericCellImpl {
    async fn write(
        self: Rc<Self>,
        params: writable::WriteParams<capnp::any_pointer::Owned>,
        mut results: writable::WriteResults<capnp::any_pointer::Owned>,
    ) -> Result<(), capnp::Error> {
        let value = params.get()?.get_value()?;
        *self.value.borrow_mut() = Some(serialize_any_pointer(value)?);
        let mut revision = self.revision.borrow_mut();
        *revision += 1;
        results.get().set_new_revision(*revision);
        Ok(())
    }
}

impl read_write::Server<capnp::any_pointer::Owned> for GenericCellImpl {
    async fn compare_and_swap(
        self: Rc<Self>,
        params: read_write::CompareAndSwapParams<capnp::any_pointer::Owned>,
        mut results: read_write::CompareAndSwapResults<capnp::any_pointer::Owned>,
    ) -> Result<(), capnp::Error> {
        let p = params.get()?;
        let expected = serialize_any_pointer(p.get_expected()?)?;
        let replacement = serialize_any_pointer(p.get_replacement()?)?;
        let mut current = self.value.borrow_mut();
        let swapped = current.as_ref() == Some(&expected);
        let mut r = results.get();
        r.set_swapped(swapped);
        if let Some(bytes) = current.as_ref() {
            let msg = capnp::serialize::read_message_from_flat_slice(
                &mut &bytes[..],
                Default::default(),
            )?;
            let actual: capnp::any_pointer::Reader =
                msg.get_root::<capnp::any_pointer::Reader>()?;
            r.set_actual(actual)?;
        }
        if swapped {
            *current = Some(replacement);
            *self.revision.borrow_mut() += 1;
        }
        r.set_revision(*self.revision.borrow());
        Ok(())
    }
}

struct GenericRepositoryImpl {
    store: Rc<RefCell<HashMap<Vec<u8>, (Vec<u8>, u64)>>>,
    revision: Rc<RefCell<u64>>,
}

impl GenericRepositoryImpl {
    fn new() -> Self {
        Self {
            store: Rc::new(RefCell::new(HashMap::new())),
            revision: Rc::new(RefCell::new(0)),
        }
    }
}

impl repository::Server<capnp::any_pointer::Owned, capnp::any_pointer::Owned>
    for GenericRepositoryImpl
{
    async fn get(
        self: Rc<Self>,
        params: repository::GetParams<capnp::any_pointer::Owned, capnp::any_pointer::Owned>,
        mut results: repository::GetResults<capnp::any_pointer::Owned, capnp::any_pointer::Owned>,
    ) -> Result<(), capnp::Error> {
        let key = serialize_any_pointer(params.get()?.get_key()?)?;
        let store = self.store.borrow();
        let mut r = results.get();
        if let Some((bytes, rev)) = store.get(&key) {
            r.set_revision(*rev);
            let msg = capnp::serialize::read_message_from_flat_slice(
                &mut &bytes[..],
                Default::default(),
            )?;
            let value: capnp::any_pointer::Reader =
                msg.get_root::<capnp::any_pointer::Reader>()?;
            let mut opt = r.get_result()?;
            opt.set_some(value)?;
        } else {
            r.set_revision(0);
            r.get_result()?.set_none(());
        }
        Ok(())
    }

    async fn put(
        self: Rc<Self>,
        params: repository::PutParams<capnp::any_pointer::Owned, capnp::any_pointer::Owned>,
        mut results: repository::PutResults<capnp::any_pointer::Owned, capnp::any_pointer::Owned>,
    ) -> Result<(), capnp::Error> {
        let p = params.get()?;
        let key = serialize_any_pointer(p.get_key()?)?;
        let value = serialize_any_pointer(p.get_value()?)?;
        let mut store = self.store.borrow_mut();
        let mut revision = self.revision.borrow_mut();
        *revision += 1;
        let new_revision = *revision;
        let mut r = results.get();
        r.set_new_revision(new_revision);
        if let Some((bytes, _)) = store.get(&key) {
            let msg = capnp::serialize::read_message_from_flat_slice(
                &mut &bytes[..],
                Default::default(),
            )?;
            let previous: capnp::any_pointer::Reader =
                msg.get_root::<capnp::any_pointer::Reader>()?;
            let mut prev = r.get_previous()?;
            prev.set_some(previous)?;
        } else {
            r.get_previous()?.set_none(());
        }
        store.insert(key, (value, new_revision));
        Ok(())
    }

    async fn remove(
        self: Rc<Self>,
        params: repository::RemoveParams<capnp::any_pointer::Owned, capnp::any_pointer::Owned>,
        mut results: repository::RemoveResults<
            capnp::any_pointer::Owned,
            capnp::any_pointer::Owned,
        >,
    ) -> Result<(), capnp::Error> {
        let key = serialize_any_pointer(params.get()?.get_key()?)?;
        let mut store = self.store.borrow_mut();
        let mut revision = self.revision.borrow_mut();
        *revision += 1;
        let new_revision = *revision;
        let mut r = results.get();
        r.set_new_revision(new_revision);
        if let Some((bytes, _)) = store.remove(&key) {
            let msg = capnp::serialize::read_message_from_flat_slice(
                &mut &bytes[..],
                Default::default(),
            )?;
            let removed: capnp::any_pointer::Reader =
                msg.get_root::<capnp::any_pointer::Reader>()?;
            let mut result = r.get_removed()?;
            result.set_some(removed)?;
        } else {
            r.get_removed()?.set_none(());
        }
        Ok(())
    }

    async fn list(
        self: Rc<Self>,
        _params: repository::ListParams<capnp::any_pointer::Owned, capnp::any_pointer::Owned>,
        mut results: repository::ListResults<capnp::any_pointer::Owned, capnp::any_pointer::Owned>,
    ) -> Result<(), capnp::Error> {
        let store = self.store.borrow();
        let mut entries = results.get().init_entries(store.len() as u32);
        for (i, (key, (value, _))) in store.iter().enumerate() {
            let mut entry = entries.reborrow().get(i as u32);
            let key_msg = capnp::serialize::read_message_from_flat_slice(
                &mut &key[..],
                Default::default(),
            )?;
            let key_root: capnp::any_pointer::Reader =
                key_msg.get_root::<capnp::any_pointer::Reader>()?;
            let value_msg = capnp::serialize::read_message_from_flat_slice(
                &mut &value[..],
                Default::default(),
            )?;
            let value_root: capnp::any_pointer::Reader =
                value_msg.get_root::<capnp::any_pointer::Reader>()?;
            entry.set_key(key_root)?;
            entry.set_value(value_root)?;
        }
        Ok(())
    }

    async fn open_cursor(
        self: Rc<Self>,
        _params: repository::OpenCursorParams<capnp::any_pointer::Owned, capnp::any_pointer::Owned>,
        _results: repository::OpenCursorResults<
            capnp::any_pointer::Owned,
            capnp::any_pointer::Owned,
        >,
    ) -> Result<(), capnp::Error> {
        Err(capnp::Error::failed(
            "generic openCursor: not implemented".to_string(),
        ))
    }

    async fn watch(
        self: Rc<Self>,
        _params: repository::WatchParams<capnp::any_pointer::Owned, capnp::any_pointer::Owned>,
        _results: repository::WatchResults<capnp::any_pointer::Owned, capnp::any_pointer::Owned>,
    ) -> Result<(), capnp::Error> {
        Err(capnp::Error::failed(
            "generic watch: not implemented".to_string(),
        ))
    }
}

impl repository::Server<capnp::text::Owned, complex_capnp::person::Owned> for RepositoryImpl {
    async fn get(
        self: Rc<Self>,
        params: repository::GetParams<capnp::text::Owned, complex_capnp::person::Owned>,
        mut results: repository::GetResults<capnp::text::Owned, complex_capnp::person::Owned>,
    ) -> Result<(), capnp::Error> {
        let key = params
            .get()?
            .get_key()?
            .to_str()
            .map_err(|e| capnp::Error::failed(format!("invalid key utf8: {}", e)))?
            .to_string();
        let store = self.store.borrow();
        let mut r = results.get();
        if let Some((bytes, rev)) = store.get(&key) {
            r.set_revision(*rev);
            let msg = capnp::serialize::read_message_from_flat_slice(
                &mut &bytes[..],
                Default::default(),
            )?;
            let person: complex_capnp::person::Reader =
                msg.get_root::<complex_capnp::person::Reader>()?;
            let mut opt = r.get_result()?;
            opt.set_some(person)?;
        } else {
            r.set_revision(0);
            let mut opt = r.get_result()?;
            opt.set_none(());
        }
        Ok(())
    }

    async fn put(
        self: Rc<Self>,
        params: repository::PutParams<capnp::text::Owned, complex_capnp::person::Owned>,
        mut results: repository::PutResults<capnp::text::Owned, complex_capnp::person::Owned>,
    ) -> Result<(), capnp::Error> {
        let p = params.get()?;
        let key = p
            .get_key()?
            .to_str()
            .map_err(|e| capnp::Error::failed(format!("invalid key utf8: {}", e)))?
            .to_string();
        let person_reader = p.get_value()?;

        let mut msg = capnp::message::Builder::new_default();
        msg.set_root(person_reader)?;
        let words = capnp::serialize::write_message_to_words(&msg);

        // Scoped so the store/revision RefCell borrows are dropped before
        // notify_text_person_subscribers's .await below — holding a RefCell
        // borrow across an await point risks a borrow panic if some other
        // task interleaved on this same single-threaded executor tries to
        // borrow it again before this call resumes.
        let (new_rev, previous_bytes) = {
            let mut store = self.store.borrow_mut();
            let mut rev_cell = self.revision.borrow_mut();
            *rev_cell += 1;
            let new_rev = *rev_cell;

            let mut r = results.get();
            r.set_new_revision(new_rev);

            let previous_bytes = if let Some((old_bytes, _old_rev)) = store.get(&key) {
                let old_msg = capnp::serialize::read_message_from_flat_slice(
                    &mut &old_bytes[..],
                    Default::default(),
                )?;
                let old_person: complex_capnp::person::Reader =
                    old_msg.get_root::<complex_capnp::person::Reader>()?;
                let mut prev = r.get_previous()?;
                prev.set_some(old_person)?;
                Some(old_bytes.clone())
            } else {
                let mut prev = r.get_previous()?;
                prev.set_none(());
                None
            };

            store.insert(key.clone(), (words.clone(), new_rev));
            (new_rev, previous_bytes)
        };

        let change = match previous_bytes {
            Some(previous) => TextPersonChangeKind::Updated {
                new: words,
                previous,
            },
            None => TextPersonChangeKind::Inserted(words),
        };
        notify_text_person_subscribers(&self.subscribers, &key, new_rev, change).await;

        Ok(())
    }

    async fn remove(
        self: Rc<Self>,
        params: repository::RemoveParams<capnp::text::Owned, complex_capnp::person::Owned>,
        mut results: repository::RemoveResults<capnp::text::Owned, complex_capnp::person::Owned>,
    ) -> Result<(), capnp::Error> {
        let key = params
            .get()?
            .get_key()?
            .to_str()
            .map_err(|e| capnp::Error::failed(format!("invalid key utf8: {}", e)))?
            .to_string();

        // See put()'s matching comment: scoped to drop the RefCell borrows
        // before the .await below.
        let (new_rev, removed_bytes) = {
            let mut store = self.store.borrow_mut();
            let mut rev_cell = self.revision.borrow_mut();
            *rev_cell += 1;
            let new_rev = *rev_cell;

            let mut r = results.get();
            r.set_new_revision(new_rev);

            let removed_bytes = store.remove(&key);
            if let Some((old_bytes, _)) = &removed_bytes {
                let old_msg = capnp::serialize::read_message_from_flat_slice(
                    &mut &old_bytes[..],
                    Default::default(),
                )?;
                let old_person: complex_capnp::person::Reader =
                    old_msg.get_root::<complex_capnp::person::Reader>()?;
                let mut removed = r.get_removed()?;
                removed.set_some(old_person)?;
            } else {
                let mut removed = r.get_removed()?;
                removed.set_none(());
            }
            (new_rev, removed_bytes)
        };

        // Only a key that actually existed produces a real change to notify
        // watchers about — removing a nonexistent key is a no-op.
        if let Some((old_bytes, _)) = removed_bytes {
            notify_text_person_subscribers(
                &self.subscribers,
                &key,
                new_rev,
                TextPersonChangeKind::Removed {
                    previous: old_bytes,
                },
            )
            .await;
        }

        Ok(())
    }

    async fn list(
        self: Rc<Self>,
        _params: repository::ListParams<capnp::text::Owned, complex_capnp::person::Owned>,
        mut results: repository::ListResults<capnp::text::Owned, complex_capnp::person::Owned>,
    ) -> Result<(), capnp::Error> {
        let store = self.store.borrow();
        let entries_count = store.len() as u32;
        let mut entries = results.get().init_entries(entries_count);

        for (i, (key, (bytes, _rev))) in store.iter().enumerate() {
            let mut kv = entries.reborrow().get(i as u32);
            kv.set_key(key.as_str())?;

            let msg = capnp::serialize::read_message_from_flat_slice(
                &mut &bytes[..],
                Default::default(),
            )?;
            let person: complex_capnp::person::Reader =
                msg.get_root::<complex_capnp::person::Reader>()?;
            kv.set_value(person)?;
        }

        Ok(())
    }

    async fn open_cursor(
        self: Rc<Self>,
        _params: repository::OpenCursorParams<capnp::text::Owned, complex_capnp::person::Owned>,
        mut results: repository::OpenCursorResults<capnp::text::Owned, complex_capnp::person::Owned>,
    ) -> Result<(), capnp::Error> {
        // A snapshot taken now, in unspecified order (see
        // TextPersonCursorImpl) — later put()/remove() calls do not affect
        // an already-open cursor.
        let snapshot: Vec<(String, Vec<u8>)> = self
            .store
            .borrow()
            .iter()
            .map(|(key, (bytes, _rev))| (key.clone(), bytes.clone()))
            .collect();
        let cursor: cursor::Client<
            complex_capnp::key_value::Owned<capnp::text::Owned, complex_capnp::person::Owned>,
        > = capnp_rpc::new_client(TextPersonCursorImpl {
            entries: RefCell::new(snapshot.into_iter()),
        });
        results.get().set_cursor(cursor);
        Ok(())
    }

    async fn watch(
        self: Rc<Self>,
        params: repository::WatchParams<capnp::text::Owned, complex_capnp::person::Owned>,
        mut results: repository::WatchResults<capnp::text::Owned, complex_capnp::person::Owned>,
    ) -> Result<(), capnp::Error> {
        let observer = params.get()?.get_observer()?;

        let id = {
            let mut next_id = self.next_subscription_id.borrow_mut();
            let id = *next_id;
            *next_id += 1;
            id
        };
        self.subscribers.borrow_mut().insert(id, observer);

        let subscription: subscription::Client = capnp_rpc::new_client(SubscriptionImpl {
            subscribers: self.subscribers.clone(),
            id,
        });
        results.get().set_subscription(subscription);
        Ok(())
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
    async fn write(self: Rc<Self>, params: byte_sink::WriteParams) -> Result<(), capnp::Error> {
        let chunk = params.get()?.get_chunk()?;
        self.data.borrow_mut().extend_from_slice(chunk);
        Ok(())
    }

    async fn finish(
        self: Rc<Self>,
        _params: byte_sink::FinishParams,
        mut results: byte_sink::FinishResults,
    ) -> Result<(), capnp::Error> {
        let data = self.data.borrow();
        let byte_count = data.len() as u64;
        let checksum: u8 = data.iter().fold(0u8, |acc, &b| acc ^ b);
        let mut r = results.get();
        r.set_byte_count(byte_count);
        r.set_checksum(&[checksum]);
        Ok(())
    }

    async fn abort(
        self: Rc<Self>,
        _params: byte_sink::AbortParams,
        _results: byte_sink::AbortResults,
    ) -> Result<(), capnp::Error> {
        self.data.borrow_mut().clear();
        Ok(())
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
    async fn pump_to(
        self: Rc<Self>,
        params: byte_source::PumpToParams,
        mut results: byte_source::PumpToResults,
    ) -> Result<(), capnp::Error> {
        let (sink, chunk_size, data) = {
            let p = params.get()?;
            let sink = p.get_sink()?;
            let chunk_size = p.get_chunk_size() as usize;
            let chunk_size = if chunk_size == 0 { 65536 } else { chunk_size };
            let data = self.data.clone();
            (sink, chunk_size, data)
        };

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
    }
}

// ---------------------------------------------------------------------------
// CapabilityFactoryImpl
// ---------------------------------------------------------------------------

struct CapabilityFactoryImpl;

impl capability_factory::Server for CapabilityFactoryImpl {
    async fn new_cell(
        self: Rc<Self>,
        params: capability_factory::NewCellParams,
        mut results: capability_factory::NewCellResults,
    ) -> Result<(), capnp::Error> {
        let initial_value = serialize_any_pointer(params.get()?.get_initial_value()?)?;
        let cell: read_write::Client<capnp::any_pointer::Owned> =
            capnp_rpc::new_client(GenericCellImpl::new(Some(initial_value)));
        results.get().set_cell(cell);
        Ok(())
    }

    async fn new_empty_cell(
        self: Rc<Self>,
        _params: capability_factory::NewEmptyCellParams,
        mut results: capability_factory::NewEmptyCellResults,
    ) -> Result<(), capnp::Error> {
        let cell: read_write::Client<capnp::any_pointer::Owned> =
            capnp_rpc::new_client(GenericCellImpl::new(None));
        results.get().set_cell(cell);
        Ok(())
    }

    async fn new_repository(
        self: Rc<Self>,
        _params: capability_factory::NewRepositoryParams,
        mut results: capability_factory::NewRepositoryResults,
    ) -> Result<(), capnp::Error> {
        let repository: repository::Client<capnp::any_pointer::Owned, capnp::any_pointer::Owned> =
            capnp_rpc::new_client(GenericRepositoryImpl::new());
        results.get().set_repository(repository);
        Ok(())
    }

    async fn echo_capability(
        self: Rc<Self>,
        params: capability_factory::EchoCapabilityParams,
        mut results: capability_factory::EchoCapabilityResults,
    ) -> Result<(), capnp::Error> {
        let capability = params.get()?.get_capability()?;
        results.get().set_same_capability(capability)?;
        Ok(())
    }

    async fn get_untyped(
        self: Rc<Self>,
        params: capability_factory::GetUntypedParams,
        mut results: capability_factory::GetUntypedResults,
    ) -> Result<(), capnp::Error> {
        let name = params.get()?.get_name()?.to_str().unwrap_or("");
        println!("[server] factory.getUntyped({})", name);

        let result_root = results.get();
        let value = result_root.init_value();
        match name {
            "scalars" | "AllScalars" => {
                let mut scalars = value.init_as::<complex_capnp::all_scalars::Builder>();
                scalars.set_int32_value(20260717);
                scalars.set_uint16_value(4242);
                scalars.set_text_value("untyped from Rust");
            }
            _ => {
                let mut scalars = value.init_as::<complex_capnp::all_scalars::Builder>();
                scalars.set_int32_value(-1);
                scalars.set_text_value("unknown untyped payload");
            }
        }
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// ComplexTestServiceImpl
// ---------------------------------------------------------------------------

struct ComplexTestServiceImpl {
    shutdown_tx: RefCell<Option<oneshot::Sender<()>>>,
}

impl complex_test_service::Server for ComplexTestServiceImpl {
    async fn echo(
        self: Rc<Self>,
        params: complex_test_service::EchoParams,
        mut results: complex_test_service::EchoResults,
    ) -> Result<(), capnp::Error> {
        let _req = params.get()?.get_request()?;
        let mut resp = results.get().init_response();
        resp.set_accepted(true);
        resp.set_status(complex_capnp::Status::Running);
        resp.set_message("echo from Rust");
        Ok(())
    }

    async fn echo_scalars(
        self: Rc<Self>,
        params: complex_test_service::EchoScalarsParams,
        mut results: complex_test_service::EchoScalarsResults,
    ) -> Result<(), capnp::Error> {
        let p = params.get()?;
        let value = p.get_value()?;
        println!("[server] echoScalars(boolean={})", value.get_boolean());
        results.get().set_value(value)?;
        Ok(())
    }

    async fn echo_lists(
        self: Rc<Self>,
        params: complex_test_service::EchoListsParams,
        mut results: complex_test_service::EchoListsResults,
    ) -> Result<(), capnp::Error> {
        let p = params.get()?;
        let value = p.get_value()?;
        let text_count = value.get_texts().map(|l| l.len()).unwrap_or(0);
        println!("[server] echoLists(texts.len={})", text_count);
        results.get().set_value(value)?;
        Ok(())
    }

    async fn echo_union(
        self: Rc<Self>,
        params: complex_test_service::EchoUnionParams,
        mut results: complex_test_service::EchoUnionResults,
    ) -> Result<(), capnp::Error> {
        let p = params.get()?;
        let value = p.get_value()?;
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
        results.get().set_value(value)?;
        Ok(())
    }

    async fn echo_any_pointer(
        self: Rc<Self>,
        params: complex_test_service::EchoAnyPointerParams,
        mut results: complex_test_service::EchoAnyPointerResults,
    ) -> Result<(), capnp::Error> {
        let value = params.get()?.get_value()?;
        results
            .get()
            .init_value()
            .set_as::<capnp::any_pointer::Owned>(value)?;
        Ok(())
    }

    async fn exchange_capabilities(
        self: Rc<Self>,
        params: complex_test_service::ExchangeCapabilitiesParams,
        mut results: complex_test_service::ExchangeCapabilitiesResults,
    ) -> Result<(), capnp::Error> {
        println!("[server] exchangeCapabilities");
        let p = params.get()?;
        let in_bundle = p.get_bundle()?;
        let primary = in_bundle.get_primary()?;
        let in_targets = in_bundle.get_targets()?;
        let mut out_bundle = results.get().init_bundle();
        out_bundle.set_primary(primary);
        out_bundle.set_targets(in_targets)?;
        Ok(())
    }

    async fn call_observer(
        self: Rc<Self>,
        params: complex_test_service::CallObserverParams,
        mut results: complex_test_service::CallObserverResults,
    ) -> Result<(), capnp::Error> {
        let (observer, event_count) = {
            let p = params.get()?;
            let observer: observer::Client<complex_capnp::person::Owned> = p.get_observer()?;
            let events = p.get_events()?;
            let event_count = events.len();
            println!("[server] callObserver(events={})", event_count);
            (observer, event_count)
        };

        for seq in 0..event_count {
            let mut req = observer.on_next_request();
            req.get().set_sequence(seq as u64);
            req.send().promise.await?;
        }
        observer.on_complete_request().send().promise.await?;
        results.get().set_delivered(event_count);
        Ok(())
    }

    async fn make_pipeline(
        self: Rc<Self>,
        params: complex_test_service::MakePipelineParams,
        mut results: complex_test_service::MakePipelineResults,
    ) -> Result<(), capnp::Error> {
        let depth = params.get()?.get_depth();
        println!("[server] makePipeline(depth={})", depth);
        let target: pipeline_target::Client = capnp_rpc::new_client(PipelineTargetImpl {
            name: format!("root(depth={})", depth),
        });
        results.get().set_target(target);
        Ok(())
    }

    async fn open_upload(
        self: Rc<Self>,
        _params: complex_test_service::OpenUploadParams,
        mut results: complex_test_service::OpenUploadResults,
    ) -> Result<(), capnp::Error> {
        println!("[server] openUpload()");
        let sink: byte_sink::Client = capnp_rpc::new_client(ByteSinkImpl::new());
        results.get().set_sink(sink);
        Ok(())
    }

    async fn open_download(
        self: Rc<Self>,
        params: complex_test_service::OpenDownloadParams,
        mut results: complex_test_service::OpenDownloadResults,
    ) -> Result<(), capnp::Error> {
        let p = params.get()?;
        let resource_id = p.get_resource_id()?;
        let data: Vec<u8> = match resource_id.which() {
            Ok(complex_capnp::identifier::Which::Textual(t)) => t
                .unwrap_or(capnp::text::Reader::from(""))
                .as_bytes()
                .to_vec(),
            Ok(complex_capnp::identifier::Which::Binary(d)) => d.unwrap_or(&[]).to_vec(),
            _ => b"default-data".to_vec(),
        };
        println!("[server] openDownload({} bytes)", data.len());
        let source: byte_source::Client = capnp_rpc::new_client(ByteSourceImpl::new(data));
        results.get().set_source(source);
        Ok(())
    }

    async fn get_repository(
        self: Rc<Self>,
        _params: complex_test_service::GetRepositoryParams,
        mut results: complex_test_service::GetRepositoryResults,
    ) -> Result<(), capnp::Error> {
        println!("[server] getRepository()");
        let repo: repository::Client<capnp::text::Owned, complex_capnp::person::Owned> =
            capnp_rpc::new_client(RepositoryImpl::new());
        results.get().set_repository(repo);
        Ok(())
    }

    async fn get_factory(
        self: Rc<Self>,
        _params: complex_test_service::GetFactoryParams,
        mut results: complex_test_service::GetFactoryResults,
    ) -> Result<(), capnp::Error> {
        println!("[server] getFactory()");
        let factory: capability_factory::Client = capnp_rpc::new_client(CapabilityFactoryImpl);
        results.get().set_factory(factory);
        Ok(())
    }

    async fn use_diamond(
        self: Rc<Self>,
        params: complex_test_service::UseDiamondParams,
        mut results: complex_test_service::UseDiamondResults,
    ) -> Result<(), capnp::Error> {
        let (diamond, value) = {
            let p = params.get()?;
            let diamond: diamond::Client = p.get_diamond()?;
            let value = p.get_value();
            println!("[server] useDiamond(value={})", value);
            (diamond, value)
        };

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
    }

    async fn fail_intentionally(
        self: Rc<Self>,
        params: complex_test_service::FailIntentionallyParams,
        _results: complex_test_service::FailIntentionallyResults,
    ) -> Result<(), capnp::Error> {
        let p = params.get()?;
        let code = p.get_code();
        let message = p.get_message()?.to_str().unwrap_or("").to_string();
        println!(
            "[server] failIntentionally(code={}, message=\"{}\")",
            code, message
        );
        Err(capnp::Error::failed(format!("[code={}] {}", code, message)))
    }

    async fn shutdown(
        self: Rc<Self>,
        _params: complex_test_service::ShutdownParams,
        _results: complex_test_service::ShutdownResults,
    ) -> Result<(), capnp::Error> {
        println!("[server] shutdown requested");
        if let Some(tx) = self.shutdown_tx.borrow_mut().take() {
            let _ = tx.send(());
        }
        Ok(())
    }

    async fn probe_pipeline_target(
        self: Rc<Self>,
        params: complex_test_service::ProbePipelineTargetParams,
        mut results: complex_test_service::ProbePipelineTargetResults,
    ) -> Result<(), capnp::Error> {
        let (target, payload) = {
            let p = params.get()?;
            let target: pipeline_target::Client = p.get_target()?;
            let payload = p.get_payload()?.to_vec();
            println!("[server] probePipelineTarget({} bytes)", payload.len());
            (target, payload)
        };

        let mut req = target.ping_request();
        req.get().set_payload(&payload);
        let resp = req.send().promise.await?;
        let echoed = resp.get()?.get_payload()?;
        results.get().set_payload(echoed);
        Ok(())
    }

    async fn make_promised_pipeline(
        self: Rc<Self>,
        params: complex_test_service::MakePromisedPipelineParams,
        mut results: complex_test_service::MakePromisedPipelineResults,
    ) -> Result<(), capnp::Error> {
        let delay_ms = params.get()?.get_delay_ms();
        println!("[server] makePromisedPipeline(delayMs={})", delay_ms);
        let target: pipeline_target::Client = capnp_rpc::new_future_client(async move {
            tokio::time::sleep(std::time::Duration::from_millis(delay_ms as u64)).await;
            Ok(capnp_rpc::new_client(PipelineTargetImpl {
                name: format!("promised(delay={})", delay_ms),
            }))
        });
        results.get().set_target(target);
        Ok(())
    }

    async fn echo_pipeline_target_later(
        self: Rc<Self>,
        params: complex_test_service::EchoPipelineTargetLaterParams,
        mut results: complex_test_service::EchoPipelineTargetLaterResults,
    ) -> Result<(), capnp::Error> {
        let (target, delay_ms) = {
            let p = params.get()?;
            let target: pipeline_target::Client = p.get_target()?;
            let delay_ms = p.get_delay_ms();
            println!("[server] echoPipelineTargetLater(delayMs={})", delay_ms);
            (target, delay_ms)
        };
        let promised: pipeline_target::Client = capnp_rpc::new_future_client(async move {
            tokio::time::sleep(std::time::Duration::from_millis(delay_ms as u64)).await;
            Ok(target)
        });
        results.get().set_target(promised);
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
                                shutdown_tx: RefCell::new(tx),
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
