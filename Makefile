LUACHECK ?= luacheck
LUA_SOURCES := obsidian-todos.lua

.PHONY: lint
lint:
	$(LUACHECK) $(LUA_SOURCES)
