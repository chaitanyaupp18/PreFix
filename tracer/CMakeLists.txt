# CMakeLists.txt — builds the heap tracer as a DynamoRIO client (libdr_trace.so).
# You normally do NOT call cmake by hand; the Makefile does it for you:
#     make client
# Under the hood it runs:
#     cmake -DDynamoRIO_DIR=<path>/DynamoRIO-Linux-<ver>/cmake ..
cmake_minimum_required(VERSION 3.7)
project(dr_trace)

find_package(DynamoRIO REQUIRED)

add_library(dr_trace SHARED dr_trace_client.cpp)
configure_DynamoRIO_client(dr_trace)

# Extensions the client uses:
#   drmgr  — event/instrumentation manager     drwrap — wrap malloc/free
#   drutil — compute a memory operand's address drreg  — scratch-register manager
foreach(ext drmgr drwrap drutil drreg)
  use_DynamoRIO_extension(dr_trace ${ext})
endforeach()

target_include_directories(dr_trace PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
