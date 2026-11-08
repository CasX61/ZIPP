# ZIPP – Einstieg für Entwicklung und CI.  `make help` zeigt alle Ziele.
SHELL := /bin/bash
.DEFAULT_GOAL := help

VERSION ?=
BUILD_NUMBER ?=
DMG ?= build/ZIPP.dmg

help: ## Diese Übersicht
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*## "} {printf "  \033[36m%-11s\033[0m %s\n", $$1, $$2}'

bootstrap: ## Werkzeuge installieren (Rust-Targets, XcodeGen) und Projekt erzeugen
	@command -v rustup >/dev/null || { echo "Bitte Rust installieren: https://rustup.rs"; exit 1; }
	rustup target add aarch64-apple-darwin x86_64-apple-darwin
	rustup component add clippy rustfmt
	@command -v xcodegen >/dev/null || brew install xcodegen
	ZIPP_NATIVE_ONLY=1 scripts/build-core.sh debug
	$(MAKE) project

core: ## Rust-Kern + Swift-Bindings (Release, universal)
	scripts/build-core.sh release

project: ## Xcode-Projekt aus app/project.yml erzeugen
	cd app && xcodegen generate

open: project ## Projekt in Xcode öffnen
	open app/Zipp.xcodeproj

build: project ## Debug-Build
	# Kern vorher bauen: Xcode kopiert den C-Header des xcframeworks schon beim Planen des Builds
	ZIPP_NATIVE_ONLY=1 scripts/build-core.sh debug
	xcodebuild -project app/Zipp.xcodeproj -scheme Zipp -configuration Debug -derivedDataPath build/DerivedData build

run: build ## Debug-Build starten
	open build/DerivedData/Build/Products/Debug/ZIPP.app

test: ## Alle Tests (Rust + Swift)
	cd core && cargo test --workspace
	$(MAKE) project
	ZIPP_NATIVE_ONLY=1 scripts/build-core.sh debug
	xcodebuild -project app/Zipp.xcodeproj -scheme Zipp -configuration Debug -derivedDataPath build/DerivedData test

lint: ## Formatierung und Clippy prüfen
	cd core && cargo fmt --all --check && cargo clippy --workspace --all-targets -- -D warnings

release: ## Release-App bauen (build/Release/ZIPP.app)
	scripts/build-app.sh "$(VERSION)" "$(BUILD_NUMBER)"

dmg: release ## DMG erzeugen (build/ZIPP.dmg)
	scripts/make-dmg.sh build/Release/ZIPP.app "$(DMG)"

cli: ## Kommandozeilen-Tool `zipp` (universal) als build/zipp-cli-macos.tar.gz
	scripts/build-cli.sh

fuzz: ## Format-Parser 5 Minuten fuzzen (braucht Rust nightly + cargo-fuzz)
	cd core/fuzz && cargo +nightly fuzz run archive -- -max_total_time=300 -max_len=262144

icon: ## App-Icon aus assets/AppIcon-source.png neu erzeugen
	swift scripts/make-icon.swift assets/AppIcon-source.png app/Zipp/Resources/Assets.xcassets/AppIcon.appiconset

clean: ## Build-Ordner löschen
	rm -rf build app/ZippCore/Generated
	cd core && cargo clean

.PHONY: help bootstrap core project open build run test lint release dmg cli fuzz icon clean
