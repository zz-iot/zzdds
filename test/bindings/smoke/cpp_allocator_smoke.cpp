// Binding smoke test for zzdds_cpp.hpp's allocator-injection surfaces:
// zzdds::create_factory(const ZidlAllocator*) (C-ABI-level factory/entity
// allocation) and zidl::setCppAllocator (C++ wrapper-object allocation via
// std::pmr). Compiled and run by `zig build test-bindings -Dcpp-binding=true`.
//
// Covers the Greptile-flagged PR #50 P1 finding: if the PMR allocator is
// exhausted, std::allocate_shared throws *before*
// DomainParticipantFactorySupport is constructed, so its destructor (which
// owns the only zzdds_destroy_factory(handle) call) never runs -- without
// the try/catch fix in wrapFactoryHandle, this leaks the already-created
// C-ABI factory and everything its own allocator allocated during bootstrap.
#include "zzdds_cpp.hpp"

#include <cassert>
#include <cstdio>
#include <cstdlib>

// C-level allocator for the factory itself
// (zzdds_create_factory_with_allocator) -- tracks alloc/free counts to prove
// whether zzdds_destroy_factory actually ran.
static size_t c_alloc_calls = 0, c_free_calls = 0;
static void* c_alloc(void*, size_t len, size_t) { c_alloc_calls++; return std::malloc(len); }
static bool c_resize(void*, void*, size_t, size_t, size_t) { return false; }
static void c_free(void*, void* p, size_t, size_t) { c_free_calls++; std::free(p); }

static void test_happy_path() {
    ZidlAllocator c_tracking{nullptr, c_alloc, c_resize, c_free};
    c_alloc_calls = c_free_calls = 0;
    {
        auto factory = zzdds::create_factory(&c_tracking);
        assert(factory);
        auto dp = factory->create_participant(
            0, ::DDS::DomainParticipantQos::default_value(), nullptr, 0);
        assert(dp);
    }
    assert(c_alloc_calls > 0);
    assert(c_alloc_calls == c_free_calls); // everything torn down, nothing leaked
}

// The pmr allocator is rigged to always fail, forcing
// std::allocate_shared<DomainParticipantFactorySupport> to throw bad_alloc
// -- proving wrapFactoryHandle's try/catch still tears down the already-
// created C-ABI factory instead of leaking it.
static void* failing_alloc(void*, size_t, size_t) { return nullptr; }
static bool failing_resize(void*, void*, size_t, size_t, size_t) { return false; }
static void failing_free(void*, void*, size_t, size_t) {}

static void test_pmr_exhaustion_does_not_leak_factory() {
    ZidlAllocator c_tracking{nullptr, c_alloc, c_resize, c_free};
    ZidlAllocator failing{nullptr, failing_alloc, failing_resize, failing_free};
    c_alloc_calls = c_free_calls = 0;

    zidl::setCppAllocator(&failing);
    bool threw = false;
    try {
        auto factory = zzdds::create_factory(&c_tracking);
        (void)factory;
    } catch (const std::bad_alloc&) {
        threw = true;
    }
    zidl::setCppAllocator(nullptr);

    assert(threw);
    assert(c_alloc_calls > 0); // factory bootstrap did allocate something
    assert(c_alloc_calls == c_free_calls); // ...and it was all freed, not leaked
}

int main() {
    test_happy_path();
    test_pmr_exhaustion_does_not_leak_factory();
    std::printf("cpp_allocator_smoke: OK\n");
    return 0;
}
