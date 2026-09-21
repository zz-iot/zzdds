cmake_minimum_required(VERSION 3.14)
project(zzdds_integration_delete_contained_entities_cpp CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

find_package(ZZDDS REQUIRED)

if(NOT DEFINED ZIDL_EXECUTABLE)
    set(ZIDL_EXECUTABLE "${ZZDDS_ZIDL_EXECUTABLE}")
endif()

set(GENERATED_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated")
file(MAKE_DIRECTORY "${GENERATED_DIR}")

set(SESSION_EVENT_IDL "${CMAKE_CURRENT_SOURCE_DIR}/idl/session_event.idl")

add_custom_command(
    OUTPUT "${GENERATED_DIR}/session_event.hpp" "${GENERATED_DIR}/session_event_cdr.cpp"
    COMMAND "${ZIDL_EXECUTABLE}" -b cpp --generate-interfaces --cpp-pmr-containers --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${SESSION_EVENT_IDL}"
    DEPENDS "${SESSION_EVENT_IDL}"
    COMMENT "Generating SessionEvent C++ TypeSupport from session_event.idl"
    VERBATIM
)
add_custom_target(generate_delete_contained_entities_types DEPENDS "${GENERATED_DIR}/session_event.hpp" "${GENERATED_DIR}/session_event_cdr.cpp")

add_library(delete_contained_entities_dcps_impl STATIC
    "${ZZDDS_DCPS_IMPL_CPP}"
    "${ZZDDS_ZZDDS_IMPL_CPP}"
    "${GENERATED_DIR}/session_event_cdr.cpp"
)
add_dependencies(delete_contained_entities_dcps_impl generate_delete_contained_entities_types)
target_include_directories(delete_contained_entities_dcps_impl PUBLIC "${GENERATED_DIR}")
target_link_libraries(delete_contained_entities_dcps_impl PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

add_executable(delete_contained_entities_session src/session.cpp)
target_link_libraries(delete_contained_entities_session PRIVATE delete_contained_entities_dcps_impl ZZDDS::zzdds)

add_executable(delete_contained_entities_peer src/peer.cpp)
target_link_libraries(delete_contained_entities_peer PRIVATE delete_contained_entities_dcps_impl ZZDDS::zzdds)
