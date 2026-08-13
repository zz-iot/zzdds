//! rust/spike -- the actual compile-time enforcement check.
//!
//! This file is expected to FAIL TO COMPILE. That's the point, not a bug in
//! the example -- see ../README.md's "Findings" section for the exact error
//! this is supposed to produce and why it matters. `keep_past_drop` below
//! tries to smuggle a loaned sample's data slice out past the point where
//! `LoanedSample::drop` (which calls `zzdds_return_loaned_raw`) runs --
//! exactly the "read the buffer after the loan was returned" bug this
//! spike's whole design (`.data()` borrowing from `&self`, not from the
//! outer `'a` reader lifetime) exists to make impossible, not just
//! discouraged.
//!
//! Never actually run (`main` is empty and `keep_past_drop` is never
//! called) -- only ever built, and only ever expected to fail:
//!
//!   cargo build --example escape_attempt   # must print an E0597 error
use zzdds_rust_spike::loan::{DataReaderHandle, LoanedSample};

#[allow(dead_code)]
fn keep_past_drop(reader: &DataReaderHandle) {
    let data_ref: &[u8];
    {
        let loaned = LoanedSample::take(reader).unwrap();
        // `loaned.data()` borrows from `&loaned`, a value local to this
        // block. Assigning that borrow to `data_ref`, which needs to
        // survive past the block's end, is exactly "does not live long
        // enough" -- `loaned` (and the real return_loan() call in its
        // Drop impl) goes away at the closing brace below, before
        // `data_ref` is ever read.
        data_ref = loaned.data();
    } // <- LoanedSample::drop runs here: zzdds_return_loaned_raw() fires for real

    // If the line above had compiled, this would be a genuine
    // use-after-return_loan -- reading through a pointer zzdds has already
    // told the CDR layer it's free to reuse or has already freed. It must
    // never be reachable to write in working code.
    println!("{:?}", data_ref);
}

fn main() {}
