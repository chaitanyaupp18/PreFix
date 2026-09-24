# Heap tracer — run a program under DynamoRIO and get a CSV of every
# malloc, memory access, and free.  Full guide: README.md
#
#   make all     set up DynamoRIO, build, and trace example.cpp -> example.csv
#   make         show the steps
#
# Needs Linux x86-64. 

# settings — override on the command line, e.g.  make trace PROG=./myprog SAMPLE=100
DR_VERSION ?= 10.0.0
PY  ?= python3
CXX ?= g++
# traces are written next to this Makefile (not /tmp)
OUT ?= $(CURDIR)/example_trace
# the program to trace, and its arguments
PROG ?= ./example.bin
ARGS ?=
# 1 = record every access; raise it (e.g. 100) for huge programs
SAMPLE ?= 1
# optional: path to llvm-symbolizer, to show function names in the CSV
SYMBOLIZE ?=

DR    := tools/DynamoRIO-Linux-$(DR_VERSION)
DRRUN := $(DR)/bin64/drrun
URL   := https://github.com/DynamoRIO/dynamorio/releases/download/release_$(DR_VERSION)/DynamoRIO-Linux-$(DR_VERSION).tar.gz

.DEFAULT_GOAL := help
.PHONY: help all dynamorio client example trace csv clean distclean

help:
	@echo "make all        set up + build + trace example.cpp -> example.csv"
	@echo "make dynamorio  download DynamoRIO into ./tools"
	@echo "make client     build the tracer"
	@echo "make example    compile example.cpp"
	@echo "make trace      run the program under DynamoRIO"
	@echo "make csv        convert the trace to example.csv"
	@echo "make clean      remove what we built"
	@echo ""
	@echo "your own program:  make trace PROG=./prog ARGS='in.txt' && make csv"

all: csv

# 1. get DynamoRIO (once)
dynamorio: $(DRRUN)
$(DRRUN):
	@uname -sm | grep -q 'Linux x86_64' || { echo "Needs Linux x86-64 — copy this folder to a Linux box."; exit 1; }
	mkdir -p tools
	cd tools && curl -fL -o dr.tgz "$(URL)" && tar xf dr.tgz && rm dr.tgz

# 2. build the tracer
client: build/libdr_trace.so
build/libdr_trace.so: dr_trace_client.cpp CMakeLists.txt | $(DRRUN)
	mkdir -p build
	cd build && cmake -DDynamoRIO_DIR=$(CURDIR)/$(DR)/cmake .. >/dev/null && $(MAKE) -s

# 3. compile the demo program
example: example.bin
example.bin: example.cpp
	$(CXX) -O0 -g $< -o $@

# 4. trace it (re-runs only if the tracer or program changed)
trace: $(OUT).modules.txt
$(OUT).modules.txt: build/libdr_trace.so example.bin
	$(DRRUN) -c $(CURDIR)/build/libdr_trace.so -o $(OUT) -sample $(SAMPLE) -- $(PROG) $(ARGS)

# 5. convert the trace to CSV
csv: example.csv
example.csv: $(OUT).modules.txt
	$(PY) trace_to_csv.py $(OUT) $(if $(SYMBOLIZE),--symbolize $(SYMBOLIZE)) > $@
	@echo "wrote $@ — first rows:"
	@head -5 $@

clean:
	rm -rf build example.bin example.csv $(OUT).t*.bin $(OUT).modules.txt

distclean: clean
	rm -rf tools
