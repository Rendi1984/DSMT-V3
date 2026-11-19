# DSMT — required permissions

Everything DSMT needs, in one place: what each console action requires in
Active Directory, what the machine running it needs, and what SQL Server needs.

**Read this first, because it decides everything else:** DSMT performs every
directory read and write **as the signed-in operator**, not as a service
account. So the answer to "why did that fail?" is almost always *that operator
has not been delegated that right in AD* — the fix is a delegation change in
AD, not a change in DSMT. DSMT deliberately has no permission model of its own
for directory work.

The one exception is DSMT's **own settings** (the database it points at, the
identity mode, HTTPS, the idle timeout). Nothing in AD governs those, so they
are gated by the DSMT administrator role in **Settings → Administrators**.

---

## 1. Active Directory — what each console action needs

Granted on the **OU** you want the operator to manage, inherited to the objects
inside it. Nothing here needs Domain Admin.

| Console action | Right needed | Applies to |
| --- | --- | --- |
| Browse users and groups | Read (usually granted by default) | the OU |
| Reset password | **Reset Password** extended right | descendant user objects |
| Force change at next logon | Write `pwdLastSet` | descendant user objects |
| Unlock account | Write `lockoutTime` | descendant user objects |
| Enable / disable | Write `userAccountControl` | descendant user objects |
| Create user | **Create User objects** | the OU |
| Delete user | **Delete User objects** | the OU |
| Edit user fields | Write the specific attributes (see below) | descendant user objects |
| Move between OUs | Delete User objects on the **source** + Create User objects on the **target** + Write `name` | both OUs |
| Add / remove group members | Write `member` | descendant group objects |
| Create / delete group | Create + Delete Group objects | the OU |
| gMSA tool — create the KDS root key | **Enterprise Admin** (forest-wide, once ever) | the forest |
| gMSA tool — create the gMSA | Create msDS-GroupManagedServiceAccount objects | Managed Service Accounts container |
| AD health — replication, FSMO, DC list | Read; some replication metadata needs elevated rights | domain / forest |

### The delegation, the easy way

Right-click the OU in **Active Directory Users and Computers** → **Delegate
Control** → pick the group → tick:

- Create, delete, and manage user accounts
- Reset user passwords and force password change at next logon
- Modify the membership of a group

That covers most of the table. **It does not cover enable/disable or unlock** —
those need the two attribute writes below.

### The delegation, exactly

```powershell
$ou  = "OU=Users,OU=OU,DC=LAB,DC=LOCAL"
$who = "LAB\DSMT Operators"      # a group, never an individual

# Passwords
dsacls "$ou" /I:S /G "${who}:CA;Reset Password;user"
dsacls "$ou" /I:S /G "${who}:WP;pwdLastSet;user"

# Enable / disable, and unlock
dsacls "$ou" /I:S /G "${who}:WP;userAccountControl;user"
dsacls "$ou" /I:S /G "${who}:WP;lockoutTime;user"

# Create and delete users
dsacls "$ou" /I:T /G "${who}:CC;user"
dsacls "$ou" /I:T /G "${who}:DC;user"

# Fields the New user form writes
dsacls "$ou" /I:S /G "${who}:WP;displayName;user"
dsacls "$ou" /I:S /G "${who}:WP;givenName;user"
dsacls "$ou" /I:S /G "${who}:WP;sn;user"
dsacls "$ou" /I:S /G "${who}:WP;department;user"
dsacls "$ou" /I:S /G "${who}:WP;title;user"
dsacls "$ou" /I:S /G "${who}:WP;userPrincipalName;user"

# Move between OUs also needs the RDN
dsacls "$ou" /I:S /G "${who}:WP;name;user"
dsacls "$ou" /I:S /G "${who}:WP;distinguishedName;user"

# Group membership
dsacls "$ou" /I:S /G "${who}:WP;member;group"
```

`/I:S` applies to child objects, `/I:T` to this object and its children.

### Three things that are easy to miss

- **Delete is not only for deleting.** *Move between OUs* needs Delete on the
  source OU, and **so does creating a user**: if a step after the account is
  created fails, DSMT removes the half-made account rather than leaving it
  behind. Without Delete that rollback cannot run and the console will tell
  the operator an unusable account was left in place.
- **Move needs both ends.** Delete on the source, Create on the target. Grant
  it on every OU that is a valid source or destination.
- **Delegate to a group, never to a person.** A delegation granted to an
  individual is invisible the day they leave.

---

## 2. The machine running DSMT

| Requirement | How to satisfy it |
| --- | --- |
| Windows PowerShell 5.1 | Built into Windows Server 2016+ / Windows 10+ |
| Domain-joined | to the domain being managed |
| RSAT ActiveDirectory module | `Install-WindowsFeature RSAT-AD-PowerShell` (Server) or `Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0` (Win 10/11) |
| Local administrator, **to install** | `Install-DSMT.ps1` elevates itself |
| Write to `HKLM\SOFTWARE\Rendi Group\DSMT` | The service (LocalSystem) has it. A hand-started, non-elevated `Start-DSMT.ps1` can read settings and **not save them** — the error says so |
| URL reservation, if listening on all interfaces | `netsh http add urlacl url=http://+:8080/ user="LAB\svc-dsmt"`, or run elevated |
| Bind a certificate, for HTTPS | `netsh http add sslcert` — needs elevation. Settings → HTTPS does it for you when DSMT runs elevated or as the service |
| Read `Cert:\LocalMachine\My` | For the HTTPS certificate picker |

### The account DSMT runs as

**What it needs depends entirely on the identity mode**, so decide the mode
first. In every mode it needs to write to `%ProgramData%\DSMT` and, if
configured, connect to SQL Server.

| Mode | Reads run as | Writes run as | What the service account needs in AD |
| --- | --- | --- | --- |
| `operator` (default) | the operator | the operator | **Nothing.** It never touches the directory on anyone's behalf |
| `hybrid` | the service account | the operator | Read the directory |
| `service` | the service account | **the service account** | **Everything in section 1** — every right the operators would otherwise have needed |

`LocalSystem` is the default, and on the network it presents as the computer
account `LAB\HOSTNAME$`. That is a real, authenticatable identity, which is
exactly what makes it confusing: it signs in successfully and then holds none
of the rights anyone meant to grant. A SQL login failure naming an account
that ends in `$` is this, every time. **`hybrid` and `service` both refuse to
be selected while DSMT runs as the machine account**, because pointing
directory writes at the computer is never what anyone means.

### Service mode — what to grant, and what you give up

Grant the service account the rights in **section 1**. The `dsacls` commands
there are unchanged; substitute the service account for the operator group:

```
dsacls "OU=Staff,DC=lab,DC=local" /I:S /G "LAB\svc-dsmt:CA;Reset Password;user"
```

Two consequences, both deliberate, neither reversible after the fact:

**1. Active Directory stops naming the person.** The domain controller's own
security log records the service account as the author of every change.
DSMT's audit log remains the only record tying a change to a human, and every
entry carries both — `Operator` is who asked, `ExecutedAs` is the account that
performed it. The **Executed as** column in the audit log (off by default,
enable it under *Columns*) shows it, and it is in the CSV export. If DSMT's
audit log is lost, the attribution is lost with it, so an install in service
mode should be using SQL rather than the JSONL fallback.

**2. Active Directory stops being the backstop.** In `operator` and `hybrid`
mode, an operator who should not be able to do something is refused by the DC
even if DSMT lets them ask — they genuinely lack the right. In `service` mode
the service account holds every right, so **the role model in Settings → Roles
is the only thing deciding what an operator can do.** A gap there is a real
privilege escalation rather than a button that returns 403.

If that trade is not wanted, `hybrid` gives most of the operational benefit —
consistent reads for operators with no read rights of their own — while
keeping writes, and therefore attribution and the AD backstop, on the person.

### Password never expires

A dedicated service account is normally set `PasswordNeverExpires` so the
service does not stop at a password expiry nobody is watching for. That is a
standing credential that does not rotate, so keep it out of every interactive
group, deny it interactive logon, and prefer a **gMSA**, which has no password
to expire or to leak and rotates itself. Settings → Identity builds the
command for either.

---

## 3. SQL Server (optional)

DSMT runs without it — the audit log falls back to JSONL files under `data\`,
which is announced at startup and in **About**.

| Requirement | Detail |
| --- | --- |
| Create the database on first start | `dbcreator`, or create `DSMT` by hand first |
| Normal operation | `db_datareader` + `db_datawriter` on `DSMT`, and `EXECUTE` if procedures are added |
| Which login | The account DSMT runs as. For `LocalSystem` that is `LAB\HOSTNAME$` |

Once the database and tables exist, `dbcreator` can be removed.

---

## 4. Reading a failure

| Symptom | Almost always means |
| --- | --- |
| "Access denied" on a password reset | The **operator** lacks Reset Password on that OU. The audit record says `Denied`. Fix in AD |
| Create user says an account was created but could not be completed | The operator can create but not reset passwords, **and** cannot delete — so the rollback could not run |
| 403 on a Settings change | The operator is not in a DSMT administrator group. Nothing to do with AD |
| "Listening on all interfaces fails" | Missing URL reservation, or not elevated |
| Settings will not save | Not elevated, so `HKLM` is read-only |
| The server will not start | One of three preflight checks — RSAT missing, domain unreachable, SQL unreachable. The banner names the fix |

---

## 5. What DSMT will not do for you

- **It does not delegate AD rights.** That is a security decision that depends
  on your OU structure, and a tool that silently granted rights to make its own
  buttons work would be worse than one that reports the refusal.
- **It does not hold a private key.** The HTTPS certificate is read from the
  machine store; the console never receives a `.pfx`.
- **It does not persist operator credentials.** They exist in process memory
  for the session and are gone on restart — which is why restarting signs
  everyone out.
