# touragent.nvim — command interface. Run `just` to list recipes.

default:
    @just --list

# Run the whole test suite (unit + integration) headless with mini.test
test:
    nvim --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run()"

# Run only unit tests
test-unit:
    nvim --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run({ collect = { find_files = function() return vim.fn.globpath('tests/unit', '**/test_*.lua', true, true) end } })"

# Run only integration tests (headless nvim + MCP server over stdio)
test-integration:
    nvim --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run({ collect = { find_files = function() return vim.fn.globpath('tests/integration', '**/test_*.lua', true, true) end } })"

# Run a single test file: just test-file tests/unit/test_timeline.lua
test-file file:
    nvim --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run_file('{{file}}')"

# Format check + lint + Claude plugin manifest validation
lint:
    stylua --check lua plugin mcp hooks scripts tests
    selene lua plugin mcp hooks scripts
    nvim -l scripts/validate-plugin.lua

# Format all Lua sources
fmt:
    stylua lua plugin mcp hooks scripts tests

# Launch nvim with this checkout prepended to runtimepath (private dev loop)
dev *args:
    nvim --cmd "set rtp^={{justfile_directory()}}" {{args}}

# Run the MCP server by hand (stdio) — handy for poking at it with JSON lines
mcp:
    nvim -l mcp/server.lua

# Tag a release and push it (triggers the CI build on the v* tag).
# With no argument, auto-bumps the patch of the latest v* tag (v0.0.7 → v0.0.8).
#
# This recipe is IDENTICAL across every one of the user's projects — copy it verbatim
# into any new project's .justfile. Pass an explicit tag for minor/major bumps:
#   just release           # auto patch bump
#   just release v1.0.0    # explicit
release tag="":
    #!/usr/bin/env bash
    set -euo pipefail
    tag="{{tag}}"
    if [ -z "$tag" ]; then
        last=$(git tag --list 'v*' --sort=-v:refname | head -1)
        last="${last:-v0.0.0}"
        IFS=. read -r major minor patch <<< "${last#v}"
        tag="v${major}.${minor}.$((patch + 1))"
        echo "Auto-bumping: ${last} → ${tag}"
    fi
    git tag "$tag"
    git push origin "$tag"
