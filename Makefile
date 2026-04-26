CLIPPY ?= 'clippy --all-targets --all-features -- -D warnings'
FMT ?= fmt --all -- --check

.PHONY: watch
watch:
	cargo watch -x ${CLIPPY}

.PHONY: fmt
fmt:
	cargo ${FMT}

.PHONY: test
test:
	cargo test --all-features

.PHONY: test-timeout
test-timeout:
	cargo test -- -Zunstable-options --ensure-time

.PHONY: cov
cov:
	cargo llvm-cov

.PHONY: cov-html
cov-html:
	cargo llvm-cov --html
	open target/llvm-cov/html/index.html

.PHONY: build
build:
	cargo build --all-features

.PHONY: release
release:
	cargo build --release --all-features

.PHONY: clean
clean:
	cargo clean
