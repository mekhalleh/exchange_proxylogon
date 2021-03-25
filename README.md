# exchange_proxylogon_rce

## Known issues

1. With `cmd/windows/adduser` payload, you may need to change the password
because the default password does may not meet Microsoft Windows complexity
requirements.
2. Depending on the payload used, two `cmd.exe` processes remain alive on the
server. If this is the case, you cannot make another attempt if they are not
killed. The payload `cmd\windows\generic` is safe.

 ![Alt text](./pictures/issue_02-01.png?raw=true "issue_02-01")

 ![Alt text](./pictures/issue_02-02.png?raw=true "issue_02-02")

3. Why do I have this error? `Exploit aborted due to failure: not-found: No 'OAB Id' was found`
 * This error can occur when you have never logged in to mailboxes (admin + user).

 ![Alt text](./pictures/issue_03-01.png?raw=true "issue_03-01")

4. Why do I have the message `Wait a lot (0)` to `Wait a lot (29)` and nothing
is happening?
 * Microsoft Exchange may not be installed in its default location. You can use
the advanced options to set the path if you know it.
Or use `set UseAlternatePath true` to use the alternate path (IIS root dir).

 ![Alt text](./pictures/issue_04-01.png?raw=true "issue_04-01")

For all other troubles, open an issue to describe the case and send me trace with: `set HttpTrace true`.

## Demo

[![demo](https://asciinema.org/a/401933.svg)](https://asciinema.org/a/335480?autoplay=1)
