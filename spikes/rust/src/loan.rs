//! `LoanedSample<'a>` -- the thing under test in this spike: does zzdds's
//! existing loan C-ABI (`zzdds_take_loaned_raw`/`zzdds_return_loaned_raw`, a
//! pointer valid until an explicit release call) map cleanly onto a real,
//! compiler-enforced Rust lifetime, the standard `MutexGuard`/`Ref`-shaped
//! RAII guard pattern -- or does it need `unsafe` escape hatches that quietly
//! defeat the whole point?
//!
//! Two load-bearing design choices, both deliberate, not incidental:
//!
//! 1. `return_loan` happens in `Drop`, not as a method the caller has to
//!    remember to call. This is strictly stronger than what C/C++/Java's
//!    manual `return_loan()` contract gives you today: `Drop` still runs on
//!    an early return or an unwinding panic, where a forgotten explicit call
//!    would leak.
//! 2. `data()` returns `&'b [u8]` borrowed from `&'b self` (the guard's OWN
//!    borrow scope) -- NOT `&'a [u8]` tied to the outer `DataReader`
//!    lifetime. This is the easy-to-get-wrong part: giving the slice the
//!    reader's lifetime instead of the guard's own would still compile and
//!    look safe, but would let the returned slice reference survive past
//!    `return_loan()` -- a real safety hole hiding behind a type that looks
//!    correct. `examples/escape_attempt.rs` confirms THIS (correct) version
//!    rejects the escape at compile time; the wrong-lifetime version that
//!    would let it compile anyway was not separately built -- see
//!    ../README.md's "Non-findings" for why.
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
    raw: ffi::zzdds_loaned_sample,
    info: ffi::zzdds_sample_info,
    _marker: PhantomData<&'a DataReaderHandle>,
}

impl<'a> LoanedSample<'a> {
    /// Borrows `&'a DataReaderHandle` -- the returned guard cannot outlive
    /// the reader it came from; ordinary Rust lifetime enforcement, not
    /// anything loan-specific.
    pub fn take(reader: &'a DataReaderHandle) -> Option<LoanedSample<'a>> {
        let mut raw = ffi::zzdds_loaned_sample {
            data: std::ptr::null(),
            data_len: 0,
            owner: std::ptr::null_mut(),
        };
        let mut info = ffi::zzdds_sample_info {
            valid_data: false,
            instance_state: 0,
            instance_handle: 0,
        };
        // zzdds_take_loaned_raw now returns a standard DDS_ReturnCode_t
        // (DDS_RETCODE_OK=0 -- a sample was loaned, DDS_RETCODE_NO_DATA=11 --
        // none available right now, another DDS_RETCODE_* on a real error).
        // Used to be its own non-standard 1/0/negative convention -- see
        // zidl's docs/roadmap.md "Binding design review: decision" for the
        // fix (this spike's first version got it backwards assuming the
        // standard convention applied before that fix landed).
        let rc = unsafe { ffi::zzdds_take_loaned_raw(reader.0, &mut raw, &mut info) };
        if rc != ffi::DDS_RETCODE_OK || raw.data.is_null() {
            return None;
        }
        Some(LoanedSample {
            reader: reader.0,
            raw,
            info,
            _marker: PhantomData,
        })
    }

    /// The load-bearing lifetime choice: `&'b self`, not `&'a self`. The
    /// returned slice cannot outlive this specific borrow of the guard --
    /// in particular, it cannot outlive the guard itself, which is what
    /// makes "read the data after return_loan() ran" a compile error
    /// instead of a runtime bug.
    pub fn data<'b>(&'b self) -> &'b [u8] {
        unsafe { std::slice::from_raw_parts(self.raw.data, self.raw.data_len) }
    }

    pub fn valid_data(&self) -> bool {
        self.info.valid_data
    }
}

impl<'a> Drop for LoanedSample<'a> {
    fn drop(&mut self) {
        println!("[LoanedSample::drop] returning loan (data ptr={:p})", self.raw.data);
        unsafe { ffi::zzdds_return_loaned_raw(self.reader, &mut self.raw) };
    }
}
