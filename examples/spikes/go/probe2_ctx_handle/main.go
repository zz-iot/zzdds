// go/spike probe 2 -- the Go-specific version of the "ctx pointer lifetime"
// question. Python's probe 3 found a crash (a dangling ctypes trampoline).
// Go's version of this hazard is structurally different, not just a
// relabeled copy of Python's: Go's garbage collector is a tracing
// collector, not CPython's refcounting. It decides an object is
// unreachable (and free to reclaim/reuse its memory) by scanning outward
// from a set of known roots -- goroutine stacks, globals, registered
// finalizers/handles. A raw Go pointer stashed inside a C struct's `void*`
// field is invisible to that scan: as far as Go's GC is concerned, nothing
// references the object anymore, even though C is still holding what
// amounts to a pointer to it. cgo's own pointer-passing rules exist
// specifically because of this (see cmd/cgo's "Passing pointers" doc) --
// but cgo's runtime checks (`cgocheck`) can only catch a violation AT THE
// MOMENT Go code hands a pointer to C, by inspecting that one call's
// arguments. They cannot detect "C is still using a pointer I gave it
// several calls ago" -- by then it's just C (or in this probe's case, Go
// code reading back what C stored) doing a plain memory read with zero Go
// runtime involvement at that moment. So unlike Python's crash (reliable,
// loud, SIGSEGV/SIGTRAP), the Go failure mode this probe is checking for is
// silent data corruption: does the pointed-to memory still hold what it's
// supposed to once the GC actually reclaims it and something else's
// allocation lands on the same address?
//
// --raw    Stores a raw Go pointer (via unsafe.Pointer) as listener_data,
//          with no other live Go reference kept anywhere. Between each
//          deadline tick, forces GC + heap churn to encourage the freed
//          memory to actually get reused (the same amplification technique
//          Python's probe 3 used) rather than coincidentally surviving
//          untouched, which would be a false pass.
// --handle Same setup, but listener_data is a runtime/cgo.Handle instead --
//          an opaque integer token; the real Go object stays referenced
//          from cgo's own internal handle table (a real GC root), so the
//          object is never eligible for collection while the handle exists.
//
// See ../README.md for the full probe list and findings.
package main

/*
#cgo CFLAGS: -I${SRCDIR}/../../../../zzdds/zig-out/include
#cgo LDFLAGS: -L${SRCDIR}/../../../../zzdds/zig-out/lib -lzzdds -Wl,-rpath,${SRCDIR}/../../../../zzdds/zig-out/lib
#include <stdlib.h>
#include "dcps.h"
#include "zzdds_c.h"

extern void goOnRequestedDeadlineMissed2(DDS_DataReader reader, DDS_RequestedDeadlineMissedStatus *status, void *listener_data);
extern void goOnRelease2(void *listener_data);

static inline void spike_wire_listener2(DDS_DataReaderListener *l) {
    l->on_requested_deadline_missed = (void (*)(DDS_DataReader, const DDS_RequestedDeadlineMissedStatus *, void *))goOnRequestedDeadlineMissed2;
    l->release_listener_data = goOnRelease2;
}
*/
import "C"

import (
	"fmt"
	"os"
	"runtime"
	"runtime/cgo"
	"runtime/debug"
	"time"
	"unsafe"
)

const (
	domainID          = 71
	deadlinePeriodSec = 0 // set to nanosec below for a faster tick
	deadlineNsec      = 150_000_000
	tickCount         = 15
	magicWant         = uint64(0xDEADBEEFCAFEF00D)
)

type MagicStruct struct {
	Magic uint64
	_     [256]byte // pad so it's a juicy-enough allocation to be worth reusing
}

var (
	mismatches int
	checks     int
)

func heapChurn() {
	// Allocate/discard a lot of similarly-sized garbage so whatever the
	// freed MagicStruct's memory belonged to is under real pressure to be
	// reused, not just marked free and left untouched.
	var junk [][]byte
	for i := 0; i < 20000; i++ {
		junk = append(junk, make([]byte, 264))
		if len(junk) > 2000 {
			junk = junk[1:]
		}
	}
	runtime.GC()
	debug.FreeOSMemory()
	runtime.GC()
}

//export goOnRequestedDeadlineMissed2
func goOnRequestedDeadlineMissed2(reader C.DDS_DataReader, status *C.DDS_RequestedDeadlineMissedStatus, listenerData unsafe.Pointer) {
	mode := os.Getenv("SPIKE_MODE")
	checks++

	var got uint64
	if mode == "handle" {
		h := cgo.Handle(uintptr(listenerData))
		obj := h.Value().(*MagicStruct)
		got = obj.Magic
	} else {
		obj := (*MagicStruct)(listenerData)
		got = obj.Magic
	}

	fmt.Printf("[callback] check=%d total_count=%d got=%#x want=%#x match=%v\n",
		checks, status.total_count, got, magicWant, got == magicWant)
	if got != magicWant {
		mismatches++
	}

	heapChurn()
}

//export goOnRelease2
func goOnRelease2(listenerData unsafe.Pointer) {
	fmt.Println("[callback] release_listener_data fired")
}

func main() {
	mode := os.Getenv("SPIKE_MODE")
	if mode != "raw" && mode != "handle" {
		fmt.Fprintln(os.Stderr, "usage: SPIKE_MODE=raw|handle probe2_ctx_handle")
		os.Exit(2)
	}
	fmt.Printf("[main] mode=%s\n", mode)

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
	qos.deadline.period.sec = 0
	qos.deadline.period.nanosec = C.uint32_t(deadlineNsec)

	var listener C.DDS_DataReaderListener
	C.spike_wire_listener2(&listener)

	// The object under test. No variable in main ever holds a reference
	// to it again after this block in --raw mode -- that's the point.
	obj := &MagicStruct{Magic: magicWant}
	var ctxPtr unsafe.Pointer
	var handle cgo.Handle
	if mode == "handle" {
		handle = cgo.NewHandle(obj)
		ctxPtr = unsafe.Pointer(uintptr(handle))
	} else {
		ctxPtr = unsafe.Pointer(obj)
	}
	listener.listener_data = ctxPtr
	obj = nil // drop the only other reference; only C's copy of the pointer remains (or the handle table, in --handle mode)
	runtime.GC()

	reader := C.DDS_Subscriber_create_datareader(sub, topicDesc, &qos, &listener, C.DDS_StatusMask(4))
	if reader == nil {
		fmt.Println("FAIL: create_datareader() failed")
		os.Exit(1)
	}

	fmt.Printf("[main] reader created, waiting for %d ticks with GC+heap-churn between each...\n", tickCount)
	time.Sleep(time.Duration(int64(tickCount+2) * deadlineNsec))

	C.zzdds_destroy_factory(factory)
	if mode == "handle" {
		handle.Delete()
	}

	fmt.Printf("[main] checks=%d mismatches=%d\n", checks, mismatches)
	if checks < tickCount/2 {
		fmt.Println("FAIL: too few callback ticks observed to draw a conclusion")
		os.Exit(1)
	}
	if mode == "handle" && mismatches > 0 {
		fmt.Println("FAIL: cgo.Handle mode should never mismatch -- the real object should stay referenced")
		os.Exit(1)
	}
	if mode == "raw" {
		if mismatches > 0 {
			fmt.Println("CONFIRMED: raw pointer mode silently corrupted -- got stale/reused memory instead of the original object")
		} else {
			fmt.Println("raw pointer mode did NOT show corruption in this run -- see README before trusting this (GC timing is not guaranteed)")
		}
	}
	fmt.Println("PASS")
}
