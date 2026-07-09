.PHONY: brew-local

brew-local:
	git diff --quiet Formula/sand.rb || { echo "Formula/sand.rb has uncommitted changes, aborting"; exit 1; }
	-brew uninstall sand
	-brew tap-new local/sand
	sed -i '' 's|^  head .*|  head "file://$(CURDIR)", using: :git, branch: "main"|' Formula/sand.rb
	cp Formula/sand.rb "$$(brew --repo local/sand)/Formula/sand.rb"
	git checkout Formula/sand.rb
	brew install --HEAD local/sand/sand
