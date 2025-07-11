---
name: Bug report
about: Create a report to help us improve ezserve
title: '[BUG] '
labels: bug
assignees: ''
---

## Bug Description
A clear and concise description of what the bug is.

## To Reproduce
Steps to reproduce the behavior:
1. Build ezserve with '...'
2. Run with flags '....'
3. Send request to '....'
4. See error

## Expected Behavior
A clear and concise description of what you expected to happen.

## Actual Behavior
What actually happened instead.

## Environment
- **OS**: [e.g. Ubuntu 22.04, macOS 13.0, Windows 11]
- **Zig version**: [e.g. 0.14.1]
- **ezserve version**: [e.g. v0.3.0]
- **Build mode**: [e.g. ReleaseFast, ReleaseSmall, Debug]

## Command Used
```bash
# The exact command you ran
./ezserve --port 8080 --cors
```

## Logs/Output
```
Paste any relevant log output or error messages here
```

## curl Command (if applicable)
```bash
# The curl command that reproduces the issue
curl -v http://127.0.0.1:8080/
```

## Additional Context
Add any other context about the problem here.

## Performance Impact
- [ ] This bug affects performance
- [ ] This bug causes crashes
- [ ] This bug affects security
- [ ] This bug affects usability only