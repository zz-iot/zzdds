cmake_minimum_required(VERSION 3.14)
project(zzdds_custom_allocator_c_example C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# See c/waitset/CMakeLists.txt's matching option for the full rationale.
# Particularly valuable here: static_pool_allocator.c's pthread_mutex_t-guarded
# pool is real, application-owned concurrency that TSan has never instrumented
# before this option existed.
option(CUSTOM_ALLOCATOR_SANITIZE_THREAD "Build with -fsanitize=thread (requires zzdds built with -Dsanitize-thread=true)" OFF)
if(CUSTOM_ALLOCATOR_SANITIZE_THREAD)
    add_compile_options(-fsanitize=thread -g -O1)
    add_link_options(-fsanitize=thread)
endif()

find_package(ZZDDS REQUIRED)
find_package(Threads REQUIRED)

set(GENERATED_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated")
file(MAKE_DIRECTORY "${GENERATED_DIR}")

set(SENSOR_IDL "${CMAKE_CURRENT_SOURCE_DIR}/idl/sensor.idl")

add_custom_command(
    OUTPUT "${GENERATED_DIR}/sensor.h" "${GENERATED_DIR}/sensor_cdr.c"
    COMMAND "${ZZDDS_ZIDL_EXECUTABLE}" -b c --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${SENSOR_IDL}"
    DEPENDS "${SENSOR_IDL}"
    COMMENT "Generating SensorSample TypeSupport from sensor.idl"
    VERBATIM
)
add_custom_target(generate_sensor_types DEPENDS "${GENERATED_DIR}/sensor.h" "${GENERATED_DIR}/sensor_cdr.c")

add_library(sensor_types STATIC "${GENERATED_DIR}/sensor_cdr.c")
add_dependencies(sensor_types generate_sensor_types)
target_include_directories(sensor_types PUBLIC "${GENERATED_DIR}")
target_link_libraries(sensor_types PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

add_library(static_pool_allocator STATIC src/static_pool_allocator.c)
target_include_directories(static_pool_allocator PUBLIC src)
target_link_libraries(static_pool_allocator PUBLIC ZZDDS::zzdds Threads::Threads)

# Standalone LD_PRELOAD shim (not linked into publisher/subscriber -- loaded
# only via LD_PRELOAD at run time) that aborts on any malloc/calloc/realloc/free
# once armed, making "zero heap allocation after startup" a falsifiable test.
add_library(noalloc_guard SHARED src/noalloc_guard_preload.c)
target_link_libraries(noalloc_guard PRIVATE ${CMAKE_DL_LIBS})

# Compiled into publisher/subscriber directly: resolves noalloc_guard_arm/_disarm
# via dlsym(RTLD_DEFAULT, ...) so the app runs fine (unguarded) even without
# LD_PRELOAD set.
add_library(noalloc_guard_client STATIC src/noalloc_guard_client.c)
target_include_directories(noalloc_guard_client PUBLIC src)
target_link_libraries(noalloc_guard_client PUBLIC ${CMAKE_DL_LIBS})

add_executable(publisher src/publisher.c)
target_link_libraries(publisher PRIVATE sensor_types static_pool_allocator noalloc_guard_client ZZDDS::zzdds)

add_executable(subscriber src/subscriber.c)
target_link_libraries(subscriber PRIVATE sensor_types static_pool_allocator noalloc_guard_client ZZDDS::zzdds)

# Narrow regression check for the zzdds_process_configure_from_file bootstrap
# fix specifically -- see src/bootstrap_noalloc_check.c.
add_executable(bootstrap_noalloc_check src/bootstrap_noalloc_check.c)
target_link_libraries(bootstrap_noalloc_check PRIVATE static_pool_allocator noalloc_guard_client ZZDDS::zzdds)

# publisher/subscriber both run with this directory as their cwd; zzdds's
# ambient config resolution looks for "./zzdds.toml" the first time a factory
# is created in each process (see zzdds/src/config/resolve.zig). Copied, not
# referenced in place, so `make` alone is enough to stage a runnable directory.
configure_file("${CMAKE_CURRENT_SOURCE_DIR}/zzdds.toml" "${CMAKE_CURRENT_BINARY_DIR}/zzdds.toml" COPYONLY)
