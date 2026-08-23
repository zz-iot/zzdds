//! `LoanedSample<'a>` -- the thing under test in this spike: does zzdds's
//! real, generated loan C-ABI (`DDS_DataReader_take_raw` in loan mode /
//! `DDS_DataReader_return_loan_raw`, a pointer valid until an explicit
//! release call) map cleanly onto a real, compiler-enforced Rust lifetime,
//! the standard `MutexGuard`/`Ref`-shaped RAII guard pattern -- or does it
//! need `unsafe` escape hatches that quietly defeat the whole point?
//!
//! Two load-bearing design choices, both deliberate, not incidental:
//!
//! 1. `return_loan` happens in `Drop`, not as a method the caller has to
//!    remember to call. This is strictly stronger than what C/C++/Java's
//!    manual `return_loan_raw()` contract gives you today: `Drop` still runs
//!    on an early return or an unwinding panic, where a forgotten explicit
//!    call would leak.
//! 2. `data()` returns `&'b [u8]` borrowed from `&'b self` (the guard's OWN
//!    borrow scope) -- NOT `&'a [u8]` tied to the outer `DataReader`
//!    lifetime. This is the easy-to-get-wrong part: giving the slice the
//!    reader's lifetime instead of the guard's own would still compile and
//!    look safe, but would let the returned slice reference survive past
//!    `return_loan_raw()` -- a real safety hole hiding behind a type that
//!    looks correct. `examples/escape_attempt.rs` confirms THIS (correct)
//!    version rejects the escape at compile time; the wrong-lifetime version
//!    that would let it compile anyway was not separately built -- see
//!    ../README.md's "Non-findings" for why.
//!
//! `take_raw` is batch-shaped at the C ABI (`cdr_payloads`/`sample_infos`
//! are always sequences, one independently-located descriptor per sample --
//! never a single-sample-shaped op, per docs/design/raw-loan-api.md's
//! zero-copy design). This spike always requests `max_samples = 1`;
//! `LoanedSample` deals with the length-1 batch internally, so the same
//! lifetime-safety question this spike originally probed is unchanged --
//! only the internal FFI shape is bigger now.
use crate::ffi;
use std::marker::PhantomData;

pub struct DataReaderHandle(pub(crate) ffi::DDS_DataReader);

impl DataReaderHandle {
    pub fn new(raw: ffi::DDS_DataReader) -> Self {
        DataReaderHandle(raw)
    }
}

pub struct LoanedSample<'a> {
    reader: ffi::DDS_DataReader,
    payloads: ffi::DDS_OctetSeqSeq,
    infos: ffi::DDS_SampleInfoSeq,
    hashes: ffi::DDS_OctetSeq,
    _marker: PhantomData<&'a DataReaderHandle>,
}

impl<'a> LoanedSample<'a> {
    /// Borrows `&'a DataReaderHandle` -- the returned guard cannot outlive
    /// the reader it came from; ordinary Rust lifetime enforcement, not
    /// anything loan-specific.
    pub fn take(reader: &'a DataReaderHandle) -> Option<LoanedSample<'a>> {
        // Zeroed/empty inout sequences (_maximum == 0 on entry) signal
        // "loan mode" to take_raw -- a non-zero _maximum would instead mean
        // "copy into this caller-owned buffer".
        let mut payloads = ffi::DDS_OctetSeqSeq::empty();
        let mut hashes = ffi::DDS_OctetSeq::empty();
        let mut infos = ffi::DDS_SampleInfoSeq::empty();
        let rc = unsafe {
            ffi::DDS_DataReader_take_raw(
                reader.0,
                &mut payloads,
                &mut hashes,
                &mut infos,
                ffi::DDS_HANDLE_NIL,
                std::ptr::null_mut(), // a_condition: none -- explicit masks below apply
                ffi::DDS_ANY_SAMPLE_STATE,
                ffi::DDS_ANY_VIEW_STATE,
                ffi::DDS_ANY_INSTANCE_STATE,
                1, // max_samples
            )
        };
        // take_raw returns a standard DDS_ReturnCode_t for the *call itself*
        // (DDS_RETCODE_OK=0 even when zero samples were available) -- NOT a
        // sample count. Check payloads._length, not rc, for "did we get one".
        if rc != ffi::DDS_RETCODE_OK || payloads._length == 0 {
            if !hashes._buffer.is_null() {
                unsafe { ffi::DDS_OctetSeq_free(&mut hashes) };
            }
            if !payloads._buffer.is_null() || !infos._buffer.is_null() {
                unsafe { ffi::DDS_DataReader_return_loan_raw(reader.0, &mut payloads, &mut infos) };
            }
            return None;
        }
        Some(LoanedSample { reader: reader.0, payloads, infos, hashes, _marker: PhantomData })
    }

    /// The load-bearing lifetime choice: `&'b self`, not `&'a self`. The
    /// returned slice cannot outlive this specific borrow of the guard --
    /// in particular, it cannot outlive the guard itself, which is what
    /// makes "read the data after return_loan_raw() ran" a compile error
    /// instead of a runtime bug.
    pub fn data<'b>(&'b self) -> &'b [u8] {
        // payloads._buffer[0] is this one sample's own descriptor -- the
        // batch always has exactly one entry here (max_samples was 1 and we
        // already checked payloads._length != 0 in take()).
        let desc = unsafe { &*self.payloads._buffer };
        unsafe { std::slice::from_raw_parts(desc._buffer, desc._length as usize) }
    }

    pub fn valid_data(&self) -> bool {
        unsafe { (*self.infos._buffer).valid_data }
    }
}

impl<'a> Drop for LoanedSample<'a> {
    fn drop(&mut self) {
        println!("[LoanedSample::drop] returning loan (payloads ptr={:p})", self.payloads._buffer);
        unsafe {
            ffi::DDS_DataReader_return_loan_raw(self.reader, &mut self.payloads, &mut self.infos);
            // key_hashes is the one output of take_raw NOT released via
            // return_loan_raw -- always a plain independent copy (see
            // reader.zig's buildRawOutputFromPins), freed generically.
            ffi::DDS_OctetSeq_free(&mut self.hashes);
        }
    }
}
