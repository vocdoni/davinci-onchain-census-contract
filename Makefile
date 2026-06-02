SHELL := /bin/bash

.PHONY: build test fmt

build:
	forge build

test:
	forge test

fmt:
	forge fmt --check
