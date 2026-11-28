# Build the distribution tests by default or select the shim target for older Perl interpreters.
# Build it from the root of the repository: docker build --file xt/realworld/Dockerfile .

ARG CHECK_PERL=perl536
FROM perl@sha256:91d3170a54b905f4237759ad0b8f9636a2aead9ff67200d864c2ca89eb76a96d AS tool

# cpm reads cpanfile.snapshot through Carton::Snapshot.
# Both directories stay outside the module search path, so no test of a distribution loads a module of the tool.
RUN cpanm --quiet --notest --local-lib-contained /opt/carton \
    https://cpan.metacpan.org/authors/id/M/MI/MIYAGAWA/Carton-v1.0.35.tar.gz
WORKDIR /opt/mutation
COPY cpanfile cpanfile.snapshot ./
RUN PERL5LIB=/opt/carton/lib/perl5 cpm install --local-lib-contained /opt/mutation --top-level-phase runtime \
    && rm -rf /root/.perl-cpm /root/.cpanm

FROM perl@sha256:cc3e7edf000b83217e8979124d9575409391bb07312b08c4ea237e2d3acb0046 AS perl5101
FROM perl@sha256:21171e4d8839f510a179e3dab25b22d9b784dce99a176e5f2fde99ec3f6f55db AS perl5144
FROM perl@sha256:708db9aa3c47f46ea896ddec1677cc3055c90ac6313e0798b81aaf446eab9796 AS perl5184
FROM perl5101 AS perl510
# The core library precedes site_perl on Perl 5.10, and its Test::More predates subtests.
COPY --from=perl5144 /usr/local/lib/perl5/5.14.4/Test/More.pm /usr/local/lib/perl5/5.10.1/Test/More.pm
COPY --from=perl5144 /usr/local/lib/perl5/5.14.4/Test/Builder.pm /usr/local/lib/perl5/5.10.1/Test/Builder.pm
COPY --from=perl5144 /usr/local/lib/perl5/5.14.4/Test/Builder/ /usr/local/lib/perl5/5.10.1/Test/Builder/
FROM perl5144 AS perl514
FROM perl5184 AS perl518
FROM perl:5.26@sha256:782dcd48bab11e07a017af09c1a6f54d34dbe1e262d82936f43f0e5d21055c38 AS perl526
FROM perl:5.36@sha256:4a7dcd778e99d7766a245107a5ebbd2d55ac8355560deea633f1ee52768440ac AS perl536
FROM perl:5.38@sha256:587c0c65838dca2fa760e0a0ab169f7260894f208e68f38535ca644f397470c7 AS perl538
FROM perl:5.40@sha256:a0acca124cce1dd122a262f554fbb30203db47ba4aba80b19eb404c501a563e5 AS perl540
FROM perl:5.42@sha256:2605930dd6506ed7795608d6f7ea0ff47815884087350778fa9368a2a3e0b920 AS perl542
FROM tool AS shim
USER 0:0
COPY --from=perl510 /usr/local/lib/perl5/5.10.1/ /usr/local/lib/perl5/5.10.1/
COPY --from=perl5101 /usr/local/lib/perl5/site_perl/5.10.1/ /usr/local/lib/perl5/site_perl/5.10.1/
COPY --from=perl5101 /usr/local/bin/perl5.10.1 /usr/local/bin/perl5.10.1
COPY --from=perl5144 /usr/local/lib/perl5/5.14.4/ /usr/local/lib/perl5/5.14.4/
COPY --from=perl5144 /usr/local/lib/perl5/site_perl/5.14.4/ /usr/local/lib/perl5/site_perl/5.14.4/
COPY --from=perl5144 /usr/local/bin/perl5.14.4 /usr/local/bin/perl5.14.4
COPY --from=perl5184 /usr/local/lib/perl5/5.18.4/ /usr/local/lib/perl5/5.18.4/
COPY --from=perl5184 /usr/local/lib/perl5/site_perl/5.18.4/ /usr/local/lib/perl5/site_perl/5.18.4/
COPY --from=perl5184 /usr/local/bin/perl5.18.4 /usr/local/bin/perl5.18.4
RUN useradd --home-dir /work/home --no-create-home --shell /bin/sh --uid 1000 tester
ENV HOME=/work/home TMPDIR=/work/tmp
USER 1000:1000
WORKDIR /repo
CMD ["sh", "-ec", "mkdir -p /work/tmp /work/home; for version in 5.10.1 5.14.4 5.18.4; do perl -I/opt/mutation/lib/perl5 xt/bin/measure-shim \"${version%.*}\" \"/usr/local/bin/perl$version\"; done"]

FROM ${CHECK_PERL} AS check-shim
ENV HOME=/work/home TMPDIR=/work/tmp
USER 1000:1000
ENTRYPOINT ["sh", "-ec", "mkdir -p /work/home /work/tmp && git clone --quiet /candidate.bundle /work/project && cd /work/project && exec \"$@\"", "sh"]

FROM check-shim AS check-driver
USER 0:0
COPY --from=perl510 /usr/local/bin/perl5.10.1 /usr/local/bin/perl5.10.1
COPY --from=perl510 /usr/local/lib/perl5/5.10.1/ /usr/local/lib/perl5/5.10.1/
COPY --from=perl510 /usr/local/lib/perl5/site_perl/5.10.1/ /usr/local/lib/perl5/site_perl/5.10.1/
COPY --from=tool /opt/carton /opt/carton
COPY --from=tool /usr/local/bin/cpm /usr/local/bin/cpm
WORKDIR /opt/deps
COPY cpanfile cpanfile.snapshot ./
RUN --mount=type=cache,target=/root/.perl-cpm \
    PERL5LIB=/opt/carton/lib/perl5 cpm install --workers 2 --local-lib-contained /opt/deps --top-level-phase configure,build,test,runtime
ENV PERL5LIB=/opt/deps/lib/perl5 TEST_MUTATION_SECOND_PERL=/usr/local/bin/perl5.10.1
USER 1000:1000

FROM tool AS distributions

# The archives and their dependencies arrive here, with the network, before any foreign test runs.
# A run of the image needs no network and writes below /work alone.
COPY xt/bin/realworld-prepare /opt/realworld/bin/realworld-prepare
COPY xt/realworld/distributions.toml /opt/realworld/realworld/distributions.toml
RUN --mount=type=cache,target=/root/.perl-cpm \
    perl -I/opt/mutation/lib/perl5 /opt/realworld/bin/realworld-prepare \
    /opt/realworld/realworld/distributions.toml /opt/distributions /opt/dependencies

# Some tests take another path for the superuser, so the runs belong to a user without rights.
RUN useradd --home-dir /work/home --no-create-home --shell /bin/sh --uid 1000 observer
USER 1000:1000
ENV HOME=/work/home TMPDIR=/work/tmp
WORKDIR /work
