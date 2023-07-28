# This file is inspired by github.com/neondatabase/neon's docker file.

ARG PG_MAJOR=15
ARG EXTENSION_DIR=/usr/share/postgresql/${PG_MAJOR}/extension
ARG INCLUDE_DIR=/usr/include/postgresql/${PG_MAJOR}
ARG LIB_DIR=/usr/lib/postgresql/${PG_MAJOR}
ARG BIN_DIR=${LIB_DIR}/bin
ARG PGCONFIG=${BIN_DIR}/pg_config

#########################################################################################
#
# Layer "pg-build"
# Used to copy postgres header files from, without needing postgres installed
#
#########################################################################################

FROM postgres:${PG_MAJOR}-bullseye AS pg-build

RUN apt update && \
    apt install -y postgresql-server-dev-$PG_MAJOR 


#########################################################################################
#
# Layer "build-deps"
# Used to copy postgres header files from, without needing postgres installed
#
#########################################################################################
FROM debian:bullseye-slim AS build-deps

ARG EXTENSION_DIR
ARG LIB_DIR

COPY --from=pg-build ${EXTENSION_DIR}/ ${EXTENSION_DIR}/
COPY --from=pg-build ${LIB_DIR}/ ${LIB_DIR}/

ENV CC=gcc
ENV CXX=g++

RUN apt update && \
    apt install -y git autoconf automake libtool build-essential bison flex libreadline-dev \
    zlib1g-dev libxml2-dev libcurl4-openssl-dev libossp-uuid-dev wget pkg-config libssl-dev \
    libicu-dev libxslt1-dev liblz4-dev libzstd-dev zstd clang-11


#########################################################################################
#
# Layer "vector-ext"
# compile pgvector extension
#
#########################################################################################
FROM build-deps AS vector-ext

ARG EXTENSION_DIR
ARG LIB_DIR
ARG INCLUDE_DIR
ARG PGCONFIG

ENV PGVECTOR_VERSION 0.4.4
ENV PGVECTOR_SHA 1cb70a63f8928e396474796c22a20be9f7285a8a013009deb8152445b61b72e6

COPY --from=pg-build ${EXTENSION_DIR}/ ${EXTENSION_DIR}/
COPY --from=pg-build ${LIB_DIR}/ ${LIB_DIR}/
COPY --from=pg-build ${INCLUDE_DIR}/ ${INCLUDE_DIR}/

RUN wget https://github.com/pgvector/pgvector/archive/refs/tags/v${PGVECTOR_VERSION}.tar.gz -O pgvector.tar.gz && \
    echo "${PGVECTOR_SHA} pgvector.tar.gz" | sha256sum --check && \
    mkdir pgvector-src && cd pgvector-src && tar xvzf ../pgvector.tar.gz --strip-components=1 -C . && \
    make -j $(getconf _NPROCESSORS_ONLN) OPTFLAGS="" PG_CONFIG=${PGCONFIG} && \
    make -j $(getconf _NPROCESSORS_ONLN) install OPTFLAGS="" PG_CONFIG=${PGCONFIG} && \
    echo 'trusted = true' >> ${EXTENSION_DIR}/vector.control


    
#########################################################################################
#
# Final image
#
#########################################################################################

FROM postgres:${PG_MAJOR}-bullseye

LABEL maintainer="Encore - https://encore.dev"
ARG EXTENSION_DIR
ARG LIB_DIR

ENV POSTGIS_MAJOR 3
ENV POSTGIS_VERSION 3.3.3+dfsg-1.pgdg110+1

RUN apt update \
    && apt install -y --no-install-recommends \
        postgresql-$PG_MAJOR-postgis-$POSTGIS_MAJOR=$POSTGIS_VERSION \
        postgresql-$PG_MAJOR-postgis-$POSTGIS_MAJOR-scripts=$POSTGIS_VERSION 

RUN rm -rf /var/lib/apt/lists/*
COPY --from=vector-ext ${EXTENSION_DIR}/ ${EXTENSION_DIR}/
COPY --from=vector-ext ${LIB_DIR}/ ${LIB_DIR}/