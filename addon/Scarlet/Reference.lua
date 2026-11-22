-- Reference.lua: what the client says a recipe and a spell are.
--   RQ recipe reagents, SI spell facts, SD spell descriptions
-- Codes are in docs/FORMAT.md.
local _, ns = ...

--- Called by Capture.lua right after it writes the SN line of a spell.
function ns.SpellFact(_) end
