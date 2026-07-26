# Guidelines

## General Guidelines

- Run the following commands every time you make a change:
    - forge build
    - forge fmt
    - forge test
- Fork tests need `BASE_RPC_URL` and skip themselves without it. Run them
  before calling a change done: they are what pins the contracts to the live
  Seaport, conduit and CreateX deployments.
- Dependencies are managed with soldeer, not submodules. Remappings in
  `foundry.toml` are maintained by hand, so a version bump means updating both
  `[dependencies]` and the matching remapping path.
- Never remove comments unless the code you update renders the comment
  invalid.
- Never refactor or rename code unless you are explicitly being told so.
- When removing code, do not add a comment to note the deletion of the code,
  simply delete the code.
- When providing a solution, give me a score on a scale of 1-10 about how
  confident you are in the solution.
