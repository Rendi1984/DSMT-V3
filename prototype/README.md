# Prototype - NOT the application

These two pages are the original design-tool export that DSMT was built from.
They are kept for reference only.

**Every row in them is fabricated.** The user list, the group list and the
audit log are hardcoded arrays of invented Hebrew names, `@corp.local` UPNs,
OU paths, ticket IDs and timestamps. The domain header says
`corp.local - 12 controllers` and the signed-in operator says `CORP\mcohen`;
neither reflects anything real. Every button is inert - the actions resolve to
`noop` and the dialogs' confirm buttons only close the dialog.

They are convincing precisely because they were designed to be. An audit row
reading `Denied - Missing MFA confirmation` looks like evidence of a working
system. It is not.

**Do not demo these pages to anyone who might believe the rows are real
directory objects, and do not use them to check whether a feature works.**

The real application is at the repository root:

- `server/Start-DSMT.ps1` - the server; reads live from Active Directory
- `web/` - the front end it serves

`support.js` here is a generated `dc-runtime` bundle. It is not used by the
real application, and it loads React, ReactDOM and Babel from `unpkg.com`, so
these prototype pages need internet access to render at all - another reason
they are unsuitable for the lab network the real console runs on.
