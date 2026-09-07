.PHONY: build test app universal check

build:
	swift build -c release

test:
	swift test

app:
	python3 scripts/package.py

universal:
	python3 scripts/package.py --arch universal

check:
	python3 scripts/generate-codebooks.py --check
	cd Tests/unsitTests/Fixtures && shasum -a 256 -c SHA256SUMS
	git diff --check
