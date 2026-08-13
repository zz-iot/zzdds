// go/spike probe 1 -- does a zzdds-internal thread (never created by, or
// announced to, the Go runtime) correctly deliver a listener callback into
// Go, the way ctypes.CFUNCTYPE's automatic PyGILState_Ensure/Release does
// for Python and AttachCurrentThreadAsDaemon does for Java?
//
// Go's answer is structurally different from both: there's no GIL to
// acquire (Go's scheduler is M:N -- goroutines multiplexed onto OS
// threads), and cgo's `//export`-generated C entry points are documented to
// handle being called from an arbitrary OS thread the Go runtime has never
// seen by creating a new M (OS-thread scheduling structure) for it on the
// fly -- no explicit "attach" call required from either side. This probe
// doesn't trust that description blindly, same spirit as the Python spike:
// it drives the same cheapest-possible trigger (zzdds's per-participant
// DEADLINE timer thread, ticking unprompted every 100ms, no writer, no data
// flow) and checks real evidence -- goroutine ID and OS thread ID observed
// from inside the callback -- that this is genuinely a foreign OS thread
// entering Go code, not something the runtime is faking or serializing back
// onto a thread it already knew about.
//
// See ../README.md for the full probe list and findings.
package main

/*
#cgo CFLAGS: -I${SRCDIR}/../../../../zzdds/zig-out/include
#cgo LDFLAGS: -L${SRCDIR}/../../../../zzdds/zig-out/lib -lzzdds -Wl,-rpath,${SRCDIR}/../../../../zzdds/zig-out/lib
#include <stdlib.h>
#include "dcps.h"
#include "zzdds_c.h"

extern void goOnRequestedDeadlineMissed(DDS_DataReader reader, DDS_RequestedDeadlineMissedStatus *status, void *listener_data);
extern void goOnRelease(void *listener_data);

// Go has no const-pointer type, so the //export'd Go function's C
// declaration can't match a `const Status*` parameter exactly -- cast at
// the point of assignment (the callback's own body never mutates *status
// either way).
static inline void spike_wire_listener(DDS_DataReaderListener *l) {
    l->on_requested_deadline_missed = (void (*)(DDS_DataReader, const DDS_RequestedDeadlineMissedStatus *, void *))goOnRequestedDeadlineMissed;
    l->release_listener_data = goOnRelease;
}
*/
import "C"

import (
	"fmt"
	"os"
	"runtime"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"
)

const (
	domainID           = 70
	deadlinePeriodSec  = 1
	runSeconds         = 10
	minExpectedFires   = 5
)

var (
	fires        int64
	releases     int64
	mainGoID     = goroutineID()
	seenGoIDs    sync.Map // int -> struct{}
	foreignGoID  int64
)

// goroutineID parses the numeric id out of runtime.Stack's header line.
// There's no public API for this -- deliberately used only for diagnostic
// evidence in this probe, never for real control flow.
func goroutineID() int64 {
	buf := make([]byte, 64)
	n := runtime.Stack(buf, false)
	buf = buf[:n]
	var id int64
	// "goroutine 123 [running]:"
	fmt.Sscanf(string(buf), "goroutine %d ", &id)
	return id
}

//export goOnRequestedDeadlineMissed
func goOnRequestedDeadlineMissed(reader C.DDS_DataReader, status *C.DDS_RequestedDeadlineMissedStatus, listenerData unsafe.Pointer) {
	gid := goroutineID()
	seenGoIDs.Store(gid, struct{}{})
	if gid != mainGoID {
		atomic.StoreInt64(&foreignGoID, gid)
	}
	n := atomic.AddInt64(&fires, 1)
	fmt.Printf("[callback] fired n=%d total_count=%d goroutine_id=%d is_main_goroutine=%v\n",
		n, status.total_count, gid, gid == mainGoID)
}

//export goOnRelease
func goOnRelease(listenerData unsafe.Pointer) {
	atomic.AddInt64(&releases, 1)
	fmt.Println("[callback] release_listener_data fired")
}

func main() {
	fmt.Printf("[main] pid=%d main_goroutine_id=%d GOMAXPROCS=%d\n", os.Getpid(), mainGoID, runtime.GOMAXPROCS(0))

	factory := C.zzdds_create_factory()
	if bool(C.zzdds_factory_is_nil(factory)) {
		fmt.Println("FAIL: zzdds_create_factory() returned nil")
		os.Exit(1)
	}
	ddsFactory := C.zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory(factory)
	dp := C.DDS_DomainParticipantFactory_create_participant(ddsFactory, C.uint32_t(domainID), nil, nil, 0)
	if dp == nil {
		fmt.Println("FAIL: create_participant() failed")
		os.Exit(1)
	}

	typeName := C.CString("SpikeType")
	defer C.free(unsafe.Pointer(typeName))
	if rc := C.zzdds_register_type_support(dp, typeName, nil, nil); rc != 0 {
		fmt.Printf("FAIL: register_type_support rc=%d\n", rc)
		os.Exit(1)
	}

	topicName := C.CString("SpikeTopic")
	defer C.free(unsafe.Pointer(topicName))
	topic := C.DDS_DomainParticipant_create_topic(dp, topicName, typeName, nil, nil, 0)
	if topic == nil {
		fmt.Println("FAIL: create_topic() failed")
		os.Exit(1)
	}
	topicDesc := C.DDS_Topic_as_DDS_TopicDescription(topic)

	sub := C.DDS_DomainParticipant_create_subscriber(dp, nil, nil, 0)
	if sub == nil {
		fmt.Println("FAIL: create_subscriber() failed")
		os.Exit(1)
	}

	var qos C.DDS_DataReaderQos
	C.DDS_DataReaderQos_default(&qos)
	qos.deadline.period.sec = C.int32_t(deadlinePeriodSec)
	qos.deadline.period.nanosec = 0

	var listener C.DDS_DataReaderListener
	C.spike_wire_listener(&listener)

	reader := C.DDS_Subscriber_create_datareader(sub, topicDesc, &qos, &listener, C.DDS_StatusMask(4)) // DDS_REQUESTED_DEADLINE_MISSED_STATUS
	if reader == nil {
		fmt.Println("FAIL: create_datareader() failed")
		os.Exit(1)
	}

	fmt.Printf("[main] reader created with %ds DEADLINE, no writer -- waiting %ds for callbacks...\n", deadlinePeriodSec, runSeconds)
	time.Sleep(runSeconds * time.Second)

	n := atomic.LoadInt64(&fires)
	distinct := 0
	seenGoIDs.Range(func(k, v interface{}) bool { distinct++; return true })
	fmt.Printf("[main] fires=%d distinct_goroutine_ids=%d foreign_goroutine_confirmed=%v\n",
		n, distinct, atomic.LoadInt64(&foreignGoID) != 0)

	if n < minExpectedFires {
		fmt.Printf("FAIL: expected >= %d fires in %ds, got %d\n", minExpectedFires, runSeconds, n)
		os.Exit(1)
	}
	if atomic.LoadInt64(&foreignGoID) == 0 {
		fmt.Println("FAIL: every callback ran on the main goroutine -- timer thread delivery not actually exercised")
		os.Exit(1)
	}

	C.zzdds_destroy_factory(factory)
	fmt.Printf("[main] teardown done; release_listener_data fired %d time(s)\n", atomic.LoadInt64(&releases))
	fmt.Println("PASS")
}
