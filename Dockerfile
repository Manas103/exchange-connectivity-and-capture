# Build and run the deterministic checks in the toolchain the committed outputs were produced with.
#   docker build -t exchange-connectivity .
#   docker run --rm exchange-connectivity                 # tests + validator, risk, routing oracles, Parquet/DuckDB
#   docker run --rm exchange-connectivity ctest --test-dir build
FROM ubuntu:22.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        g++ cmake make python3 python3-pip && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY requirements.txt ./
RUN pip3 install --no-cache-dir -r requirements.txt
COPY CMakeLists.txt ./
COPY include include
COPY src src
COPY tests tests
COPY python python
COPY scripts scripts
RUN cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j"$(nproc)"
CMD ["scripts/reproduce.sh"]
