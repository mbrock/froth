# Archived talents

These files are historical working notes. Froth does not load, index, or
expose them to agents, and their presence does not mean the described
capability still exists.

The original top-level `talents/` directory began as a flat, Voyager-like
skill library: filenames were the index and Git history was the archaeology.
No runtime discovery or loading contract was ever added. Over time the folder
accumulated several different kinds of material:

- operational recipes;
- model-specific prompting notes;
- design proposals;
- persona-writing notes;
- procedures for external machines;
- pipelines whose implementation has since been removed.

They are retained here only for historical reference. Do not use them as
current runbooks without verifying every module, model, path, and host.

Current application capabilities belong in the documentation of the modules
that implement them. Charlie can discover those docs through
`elixir_eval(action: "docs")`, inspect exact functions and source, and then
evaluate the live APIs. The useful podcast and voice-cloning guidance from
this archive now lives with `Froth.Podcast`.
