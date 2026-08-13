//! rust/spike -- does zzdds's existing `take_loaned`/`return_loan` C-ABI map
//! cleanly onto a real, borrow-checker-enforced Rust lifetime (the `zig-ffi`
//! backend mode's whole value proposition), using the API as it exists
//! *today* -- a plain heap-allocated copy behind the loan, not real
//! zero-copy/SHMEM yet. That's deliberate: the lifetime/safety question is
//! about the CONTRACT shape (pointer valid until an explicit release call),
//! which is identical regardless of what backs the pointer, not about
//! whether the bytes happen to be zero-copied yet. See ../README.md.
use zzdds_rust_spike::ffi;
use zzdds_rust_spike::loan::{DataReaderHandle, LoanedSample};
use std::ffi::CString;
use std::os::raw::c_void;

const DOMAIN_ID: u32 = 80;
const MAGIC: u64 = 0xFEEDFACECAFEBEEF;

fn main() {
    unsafe {
        let factory = ffi::zzdds_create_factory();
        assert!(!ffi::zzdds_factory_is_nil(factory), "zzdds_create_factory() returned nil");
        let dds_factory = ffi::zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory(factory);

        let dp = ffi::DDS_DomainParticipantFactory_create_participant(
            dds_factory,
            DOMAIN_ID,
            std::ptr::null(),
            std::ptr::null(),
            0,
        );
        assert!(!dp.is_null(), "create_participant() failed");

        let type_name = CString::new("SpikeLoanType").unwrap();
        let rc = ffi::zzdds_register_type_support(dp, type_name.as_ptr(), std::ptr::null(), std::ptr::null());
        assert_eq!(rc, ffi::DDS_RETCODE_OK, "register_type_support failed rc={}", rc);

        let topic_name = CString::new("SpikeLoanTopic").unwrap();
        let topic = ffi::DDS_DomainParticipant_create_topic(
            dp,
            topic_name.as_ptr(),
            type_name.as_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            0,
        );
        assert!(!topic.is_null(), "create_topic() failed");
        let topic_desc = ffi::DDS_Topic_as_DDS_TopicDescription(topic);

        let pub_ = ffi::DDS_DomainParticipant_create_publisher(dp, std::ptr::null(), std::ptr::null(), 0);
        assert!(!pub_.is_null(), "create_publisher() failed");
        let mut writer_qos = vec![0u8; ffi::spike_sizeof_writer_qos()];
        ffi::DDS_Publisher_get_default_datawriter_qos(pub_, writer_qos.as_mut_ptr() as *mut c_void);
        ffi::spike_set_writer_reliable_keep_all(writer_qos.as_mut_ptr() as *mut c_void);
        let writer = ffi::DDS_Publisher_create_datawriter(
            pub_,
            topic,
            writer_qos.as_ptr() as *const c_void,
            std::ptr::null(),
            0,
        );
        assert!(!writer.is_null(), "create_datawriter() failed");

        let sub = ffi::DDS_DomainParticipant_create_subscriber(dp, std::ptr::null(), std::ptr::null(), 0);
        assert!(!sub.is_null(), "create_subscriber() failed");
        let mut reader_qos = vec![0u8; ffi::spike_sizeof_reader_qos()];
        ffi::DDS_Subscriber_get_default_datareader_qos(sub, reader_qos.as_mut_ptr() as *mut c_void);
        let reader_handle_raw = ffi::DDS_Subscriber_create_datareader(
            sub,
            topic_desc,
            reader_qos.as_ptr() as *const c_void,
            std::ptr::null(),
            0,
        );
        assert!(!reader_handle_raw.is_null(), "create_datareader() failed");
        let reader = DataReaderHandle::new(reader_handle_raw);

        // Plain XCDR1-LE encapsulation header (0x0001, per OMG CDR PSM) +
        // an 8-byte payload. zzdds's core never interprets these bytes for a
        // keyless, unfiltered type -- this only needs to round-trip
        // byte-for-byte, not satisfy any real IDL-generated marshaling.
        let mut payload = vec![0x00u8, 0x01, 0x00, 0x00];
        payload.extend_from_slice(&MAGIC.to_le_bytes());
        let key_hash = [0u8; 16];

        // RELIABLE+KEEP_ALL means a write before the reader has finished
        // matching still gets delivered once matching completes -- but
        // write repeatedly rather than betting the whole probe on getting
        // the initial discovery wait exactly right on any given machine.
        let loaned_opt = 'outer: loop {
            let mut wrote_any = false;
            for _ in 0..15 {
                let rc = ffi::zzdds_write_raw(
                    writer,
                    key_hash.as_ptr(),
                    ffi::DDS_HANDLE_NIL,
                    payload.as_ptr(),
                    payload.len(),
                );
                assert_eq!(rc, ffi::DDS_RETCODE_OK, "zzdds_write_raw failed rc={}", rc);
                if !wrote_any {
                    println!("[main] wrote {} bytes (retrying until matched+delivered)", payload.len());
                    wrote_any = true;
                }
                if let Some(l) = LoanedSample::take(&reader) {
                    break 'outer Some(l);
                }
                std::thread::sleep(std::time::Duration::from_millis(300));
            }
            break None;
        };
        {
            let loaned: LoanedSample = loaned_opt.expect("take_loaned returned no data after polling");
            println!(
                "[main] loaned {} bytes, valid_data={}",
                loaned.data().len(),
                loaned.valid_data()
            );
            let got_magic = u64::from_le_bytes(loaned.data()[4..12].try_into().unwrap());
            assert_eq!(got_magic, MAGIC, "loaned payload didn't match what was written");
            println!("[main] payload verified: {:#x}", got_magic);
            // `loaned` drops here, at the end of this block -- return_loan
            // fires automatically, not via an explicit call.
        }

        println!("[main] loan returned via Drop, not an explicit call -- correct usage confirmed");

        ffi::zzdds_destroy_factory(factory);
        println!("PASS");
    }
}
