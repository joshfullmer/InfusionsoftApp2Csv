require 'fileutils'
require 'csv'

class App2csvController < ApplicationController

  @@app_cred ||= {}
  @src_prod_count ||= 0
  @src_tag_count ||= 0

  def step1
    @@app_cred = {
      src_app: params[:src_appname],
      src_key: params[:src_apikey],
      dest_app: params[:dest_appname],
      dest_key: params[:dest_apikey]
    }

    FileUtils::mkdir_p Rails.root.join('public',@@app_cred[:src_app])

    initialize_infusionsoft(@@app_cred[:src_app], @@app_cred[:src_key])

    puts '| Creating User Relationships'
    @@user_rel = {}
    get_table('User').map { |u| @@user_rel[u['Id']] = "#{u['FirstName']} #{u['LastName']}"}


    initialize_infusionsoft(@@app_cred[:dest_app], @@app_cred[:dest_key])
    @@src_contact_id = create_custom_field('Source App Contact ID')['Name']
    @@src_company_id = create_custom_field('Source App Company ID')['Name']
    @@src_account_id = create_custom_field('Source App Company ID',0,'Company','Text')['Name']

    contacts if params[:contacts][:checkbox] == 'true'
    companies if params[:companies][:checkbox] == 'true'
    tags if params[:tags][:checkbox] == 'true'
    products if params[:products][:checkbox] == 'true'

  end

  def contacts
    puts '| Generating Contact CSV'
    initialize_infusionsoft(@@app_cred[:src_app], @@app_cred[:src_key])

    puts '|| Getting Source Data'
    src_custom_fields = get_table('DataFormField')
    contact_fields = FIELDS['Contact'].map(&:clone)
    src_custom_fields.each { |cf| contact_fields.push('_' + cf['Name']) if cf['FormId'] == -1 }

    src_contacts = get_table('Contact',contact_fields)#,{'Id' => 4})

    fields_with_data = []
    src_contacts.each { |c| fields_with_data |= c.keys }
    cfs_to_import = fields_with_data.grep(/^_/)
    src_custom_fields.reject! { |cf| cfs_to_import.exclude? '_' + cf['Name'] }

    opted_out_emails = get_table('EmailAddStatus').select { |email| OPT_OUT_STATUSES.include? email['Type'] }

    src_ls_cat = get_table('LeadSourceCategory')
    src_ls = get_table('LeadSource')

    puts '|| Destination App'

    initialize_infusionsoft(@@app_cred[:dest_app], @@app_cred[:dest_key])

    dest_ls_cat = {}
    get_table('LeadSourceCategory').each { |cat| dest_ls_cat[cat['Id']] = cat['Name'] }

    dest_ls = {}
    get_table('LeadSource').each { |ls| dest_ls[ls['Id']] = ls['Name'] }

    cat_rel = {}
    src_ls_cat.each { |cat|
      cat_rel[cat['Id']] = dest_ls_cat.key(cat['Name']) || Infusionsoft.data_add('LeadSourceCategory',cat)
    }

    ls_rel = {0=>0}
    src_ls.each do |ls|
      ls['LeadSourceCategoryId'] = cat_rel[ls['LeadSourceCategoryId']] unless ls['LeadSourceCategoryId'] == 0
      ls_rel[ls['Id']] = dest_ls.key(ls['Name']) || Infusionsoft.data_add('LeadSource',ls)
    end

    rename_mapping = {}

    src_custom_fields.each do |cf|
      next if cf.nil? || cf['DataType'] == 25 || cf['FormId'] != -1
      field = create_custom_field(cf['Label'],0,'Contact',DATATYPES[DATATYPE_IDS[cf['DataType']]]['dataType'],cf['Values'])
      rename_mapping['_' + cf['Name']] = field['Name']
    end

    rename_mapping['Id'] = @@src_contact_id
    rename_mapping['CompanyID'] = @@src_company_id

    dest_cat_id = Infusionsoft.data_query('ContactGroupCategory',1000,0,{'CategoryName' => 'Application Transfer'},['Id'])
    dest_tag_id = Infusionsoft.data_query('ContactGroup',
                                              1000,
                                              0,
                                              {'GroupCategoryId' => dest_cat_id.first['Id'], 'GroupName' => "Data from #{@@app_cred[:src_app]}"},
                                              ['Id']) unless dest_cat_id.to_a.empty?

    tag_cat_id = dest_cat_id.to_a.empty? ? Infusionsoft.data_add('ContactGroupCategory',{'CategoryName' => 'Application Transfer'}) : dest_cat_id.first['Id']
    dest_tag_id.to_a.empty? ? Infusionsoft.data_add('ContactGroup',{'GroupCategoryId' => tag_cat_id, 'GroupName' => "Data from #{@@app_cred[:src_app]}"}) : dest_tag_id.first['Id']

    dest_contacts = get_table("Contact",[@@src_contact_id],{@@src_contact_id => "_%"}).map { |c| c[@@src_contact_id]}

    dest_emails = []
    headers = src_contacts.flat_map(&:keys).uniq
    headers << 'TransferTag'
    headers << @@src_contact_id
    headers << @@src_company_id
    headers -= ['ContactNotes']
    headers.sort!
    CSV.open(Rails.root.join('public',@@app_cred[:src_app],'contacts.csv'),'wb+') do |csv|
      csv << headers
      src_contacts.each do |c|
        next if dest_contacts.include? c['Id'].to_s
        c.each_key { |k| c[k] = c[k].to_time.strftime("%Y-%m-%d %H:%M:%S") if c[k].is_a? XMLRPC::DateTime }
        c.keys.each { |k| c[rename_mapping[k]] = c.delete(k) if rename_mapping[k]}
        c.delete('AccountId')
        c['LeadSourceId'] = ls_rel[c['LeadSourceId']]
        c['OwnerID'] = @@user_rel[c['OwnerID']] || ''
        c['TransferTag'] = "Data from #{@@app_cred[:src_app]}"
        csv << c.values_at(*headers)
        dest_emails |= [c['Email']]
      end
    end

    CSV.open(Rails.root.join('public',@@app_cred[:src_app],'email_opt_outs.csv'),'wb+') do |csv|
      csv << ['Opted Out Email Address']
      opted_out_emails.each do |e|
        csv << [e['Email']]
      end unless opted_out_emails.nil?
    end
  end

  def companies
    puts '| Generating Company CSV'
    initialize_infusionsoft(@@app_cred[:src_app], @@app_cred[:src_key])

    puts '|| Source Data'
    src_custom_fields = get_table('DataFormField')
    company_fields = FIELDS['Company'].map(&:clone)
    src_custom_fields.each { |cf| company_fields.push("_" + cf['Name']) if cf['FormId'] == -6 }

    src_companies = get_table('Company',company_fields)

    fields_with_data = []
    src_companies.each { |c| fields_with_data |= c.keys }
    cfs_to_import = fields_with_data.grep(/^_/)
    src_custom_fields.reject! { |cf| cfs_to_import.exclude? '_' + cf['Name']}

    puts '|| Destination Data'
    initialize_infusionsoft(@@app_cred[:dest_app], @@app_cred[:dest_key])

    rename_mapping = {}
    src_custom_fields.each do |cf|
      next if cf['FormId'] != -6
      field = create_custom_field(cf['Label'],0,'Company',DATATYPES[DATATYPE_IDS[cf['DataType']]]['dataType'],cf['Values'])
      rename_mapping['_' + cf['Name']] = field['Name']
    end

    rename_mapping['Id'] = @@src_account_id

    dest_companies = get_table("Company",[@@src_account_id],{@@src_account_id => "_%"}).map { |c| c[@@src_account_id]}

    headers = src_companies.flat_map(&:keys).uniq
    headers.sort!
    CSV.open(Rails.root.join('public',@@app_cred[:src_app],'companies.csv'),'wb+') do |csv|
      csv << headers
      src_companies.each do |c|
        next if dest_companies.include? c['Id'].to_s
        c.each_key { |k| c[k] = c[k].to_time.strftime("%Y-%m-%d %H:%M:%S") if c[k].is_a? XMLRPC::DateTime }
        c.keys.each { |k| c[ rename_mapping[k] ] = c.delete(k) if rename_mapping[k] }
        c['OwnerID'] = @@user_rel[c['OwnerID']] || ''
        csv << c.values_at(*headers) unless c.nil?
      end
    end

  end

  def tags
    puts '| Transferring Tags'
    initialize_infusionsoft(@@app_cred[:src_app], @@app_cred[:src_key])

    puts '|| Source Data'
    src_cats = get_table('ContactGroupCategory')
    src_tags = get_table('ContactGroup')

    tags_on_contacts = []
    get_table('Contact').each { |c| tags_on_contacts |= c['Groups'].split(",") unless c['Groups'].nil? }
    src_tags.reject! { |t| tags_on_contacts.exclude? t['Id'].to_s}
    @src_tag_count = src_tags.length.to_s

    puts '|| Destination Data'
    initialize_infusionsoft(@@app_cred[:dest_app], @@app_cred[:dest_key])

    dest_tag_cats = {}
    get_table('ContactGroupCategory').each { |c| dest_tag_cats[c['Id']] = c['CategoryName'] }

    dest_tags = {}
    get_table('ContactGroup').each { |t| dest_tags[t['Id']] = t['GroupName'] }

    cat_rel = {}
    src_cats.each do |c|
      cat_rel[c['Id']] = dest_tag_cats.key(c['CategoryName']) || Infusionsoft.data_add('ContactGroupCategory',c)
    end

    puts "|| Creating Tags"
    @@tag_rel = {}
    src_tags.each do |t|
      t['GroupCategoryId'] = cat_rel[t['GroupCategoryId']] unless t['GroupCategoryId'] == 0
      @@tag_rel[t['Id']] = dest_tags.key(t['GroupName']) || Infusionsoft.data_add('ContactGroup',t)
    end

  end

  def products
    puts '| Generating Product CSV'
    initialize_infusionsoft(@@app_cred[:src_app],@@app_cred[:src_key])

    puts '|| Source Data'
    src_products = get_table('Product')
    src_prod_cats = get_table('ProductCategory')
    src_cat_assign = get_table('ProductCategoryAssign')
    src_sub_plans = get_table('SubscriptionPlan')


    puts '|| Dest Data'
    initialize_infusionsoft(@@app_cred[:dest_app],@@app_cred[:dest_key])

    dest_products = {}
    get_table('Product').each { |p| dest_products[p['Id']] = p['ProductName'] }

    dest_prod_cats = {}
    get_table('ProductCategory').each { |c| dest_prod_cats[c['Id']] = c['CategoryDisplayName'] }

    dest_sub_plans = get_table('SubscriptionPlan')

    puts "||| Importing Products"
    @@prod_rel = {0=>0}
    src_products.each do |p|
      @@prod_rel[p['Id']] = dest_products.key(p['ProductName']) || Infusionsoft.data_add('Product',p)
    end
    @src_prod_count = @@prod_rel.keys.size

    puts "||| Importing Subscription Plans"
    @@sub_rel = {}
    src_sub_plans.each do |s|
      do_not_import = false
      dest_sub_plans.each do |p|
        do_not_import = s['PlanPrice'] == p['PlanPrice'] && s['NumberOfCycles'] == p['NumberOfCycles'] && @@prod_rel[s['ProductId']] == p['ProductId']
        @@sub_rel[s['Id']] = p['Id'] if do_not_import
        break if do_not_import
      end
      s['ProductId'] = @@prod_rel[s['ProductId']]
      do_not_import ||= s['ProductId'].nil?
      @@sub_rel[s['Id']] = Infusionsoft.data_add('SubscriptionPlan',s) unless do_not_import
    end

    puts "||| Importing Product Categories"
    cat_rel = {}
    src_prod_cats.each do |c|
      cat_rel[c['Id']] = dest_prod_cats.key(c['CategoryDisplayName']) || Infusionsoft.data_add('ProductCategory',c)
    end

    puts "||| Attaching Products to Categories"
    dest_category_assign = get_table('ProductCategoryAssign')
    already_imported = {}
    src_cat_assign.each do |a|
      next if already_imported[@@prod_rel[a['ProductId']]] == cat_rel[a['ProductCategoryId']]
      do_not_import = false
      dest_category_assign.each do |c|
        do_not_import = (@@prod_rel[a['ProductId']] == c['ProductId'] && cat_rel[a['ProductCategoryId']] == c['ProductCategoryId']) || cat_rel[a['ProductCategoryId']].nil?
        break if do_not_import
      end
      Infusionsoft.data_add('ProductCategoryAssign',{'ProductId' => @@prod_rel[a['ProductId']], 'ProductCategoryId' => cat_rel[a['ProductCategoryId']]}) unless do_not_import
      already_imported[@@prod_rel[a['ProductId']]] = cat_rel[a['ProductCategoryId']]
    end
  end

#===============================================================================

  def step2
    initialize_infusionsoft(@@app_cred[:dest_app],@@app_cred[:dest_key])

    puts '| Creating Contact Relationships'
    @@con_rel = {}
    get_table('Contact',['Id',@@src_contact_id],{@@src_contact_id => '_%'}).each { |contact| @@con_rel[contact[@@src_contact_id].to_i] = contact['Id'] }

    puts '| Creating Company Relationships'
    @@comp_rel = {}
    get_table('Company',['Id',@@src_account_id],{@@src_account_id => '_%'}).each { |company| @@comp_rel[company[@@src_account_id].to_i] = company['Id'] }

    @@src_order_id = create_custom_field('Source App Order ID',0,'Job','Text')['Name']

    tags_for_contacts if params[:tags_for_contacts][:checkbox] == 'true'
    notes if params[:notes][:checkbox] == 'true'
    tasks_appointments if params[:tasks_appointments][:checkbox] == 'true'
    opportunities if params[:opportunities][:checkbox] == 'true'
    orders if params[:orders][:checkbox] == 'true'
    subscriptions if params[:subscriptions][:checkbox] == 'true'
  end

  def tags_for_contacts
    puts '| Generating Tags for Contacts CSV'

    puts '|| Source Data'
    initialize_infusionsoft(@@app_cred[:src_app],@@app_cred[:src_key])

    src_tag_assign = get_table('ContactGroupAssign')

    puts '|| Destination Data'
    initialize_infusionsoft(@@app_cred[:dest_app],@@app_cred[:dest_key])

    puts '|| Creating CSV'
    CSV.open(Rails.root.join('public',@@app_cred[:src_app],'tags_for_contacts.csv'),'wb+') do |csv|
      csv << ['ContactId','TagId']
      src_tag_assign.each do |a|
        next if @@con_rel[a['ContactId']].nil? && @@comp_rel[a['Contact.CompanyID']].nil?
        a['GroupId'] = @@tag_rel[a['GroupId']]
        @@con_rel[a['ContactId']].nil? ? csv << [@@comp_rel[a['Contact.CompanyID']], a['GroupId']] : csv << [@@con_rel[a['ContactId']], a['GroupId']]
      end
    end
  end

  def notes
    puts '| Generating Notes CSV'

    puts '|| Source Data'
    initialize_infusionsoft(@@app_cred[:src_app], @@app_cred[:src_key])

    src_notes = get_table('ContactAction',[],{'ObjectType' => 'Note'})

    puts '|| Destination Data'
    initialize_infusionsoft(@@app_cred[:dest_app], @@app_cred[:dest_key])

    puts "|| Creating Custom Field for FKID"
    @@src_action_id = create_custom_field('Source App Action ID',0,'ContactAction','Text')['Name']

    dest_notes = get_table('ContactAction',[@@src_action_id],{@@src_action_id => '_%','ObjectType' => 'Note'}).map { |c| c[@@src_action_id]}

    puts "|| Creating CSV"

    headers = src_notes.flat_map(&:keys).uniq
    headers << @@src_action_id
    headers.sort!
    CSV.open(Rails.root.join('public',@@app_cred[:src_app],'notes.csv'),'wb+') do |csv|
      csv << headers
      src_notes.each do |n|
        next if @@con_rel[n['ContactId']].nil? || dest_notes.include?(n['Id'].to_s)
        n.each_key { |k| n[k] = n[k].to_time.strftime("%Y-%m-%d %H:%M:%S") if n[k].is_a? XMLRPC::DateTime }
        n.except!('OpportunityId')
        n[@@src_action_id] = n['Id'].to_s
        n['ContactId'] = @@con_rel[n['ContactId']]
        n['UserID'] = @@user_rel[n['UserID']] || ""
        csv << n.values_at(*headers) unless n.nil?
      end
    end
  end

  def tasks_appointments
    puts '| Generating Tasks/Appointments CSV'

    puts '|| Source Data'
    initialize_infusionsoft(@@app_cred[:src_app], @@app_cred[:src_key])

    src_tasks = get_table('ContactAction',[],{'ObjectType' => 'Task'})
    src_appts = get_table('ContactAction',[],{'ObjectType' => 'Appointment'})
    src_actions = src_tasks + src_appts

    puts '|| Destination Data'
    initialize_infusionsoft(@@app_cred[:dest_app], @@app_cred[:dest_key])

    puts "|| Creating Custom Field for FKID"
    @@src_action_id = create_custom_field('Source App Action ID',0,'ContactAction','Text')['Name']

    dest_tasks = get_table('ContactAction',[@@src_action_id],{@@src_action_id => '_%','ObjectType' => 'Task'}).map { |c| c[@@src_action_id]}
    dest_appts = get_table('ContactAction',[@@src_action_id],{@@src_action_id => '_%','ObjectType' => 'Appointment'}).map { |c| c[@@src_action_id]}
    dest_actions = dest_tasks + dest_appts

    puts "|| Creating CSV"

    default_user_id = Infusionsoft.data_get_app_setting('Templates','defuserid')
    default_user = get_table('User',[],{'Id' => default_user_id})[0]
    default_user_name = "#{default_user['FirstName']} #{default_user['LastName']}"

    headers = src_actions.flat_map(&:keys).uniq
    headers.sort!
    CSV.open(Rails.root.join('public',@@app_cred[:src_app],'tasks_appointments.csv'),'wb+') do |csv|
      csv << headers
      src_actions.each do |a|
        next if @@con_rel[a['ContactId']].nil? || dest_actions.include?(a['Id'].to_s)
        a.each_key { |k| a[k] = a[k].to_time.strftime("%Y-%m-%d %H:%M:%S") if a[k].is_a? XMLRPC::DateTime }
        a.except!('OpportunityId')
        a[@@src_action_id] = a['Id'].to_s
        a['ContactId'] = @@con_rel[a['ContactId']]
        a['UserID'] = @@user_rel[a['UserID']] || default_user_name
        csv << a.values_at(*headers) unless a.nil?
      end
    end
  end

  def opportunities
    puts '| Generating Opportunities CSV'

    puts '|| Source Data'
    initialize_infusionsoft(@@app_cred[:src_app], @@app_cred[:src_key])

    src_cfs = get_table('DataFormField')
    opp_fields = FIELDS['Lead'].map(&:clone)
    src_cfs.each { |cf| opp_fields.push("_" + cf['Name']) if cf['FormId'] == -4 }
    src_opps = get_table('Lead',opp_fields)

    stage_rel = {}
    get_table('Stage').each do |s|
      stage_rel[s['Id']] = s['StageName']
    end

    puts '|| Destination Data'
    initialize_infusionsoft(@@app_cred[:dest_app], @@app_cred[:dest_key])

    rename_mapping = {}
    src_cfs.each do |cf|
      if cf['FormId'] == -4
        field = create_custom_field(cf['Label'],0,'Opportunity',DATATYPES[DATATYPE_IDS[cf['DataType']]]['dataType'])
        rename_mapping['_' + cf['Name']] = field['Name']
        Infusionsoft.data_update_custom_field(field['Id'],{ 'Values' => cf['Values'] }) if DATATYPES[DATATYPE_IDS[cf['DataType']]]['hasValues'] == 'yes'  && customfield['Values'] != nil
      end
    end

    @@src_opp_id = create_custom_field('Source App Opportunity ID',0,'Opportunity','Text')['Name']

    dest_opps = []
    get_table("Lead",[@@src_opp_id,'Id'],{@@src_opp_id => "_%"}).each do |opp|
      dest_opps.push(opp[@@src_opp_id])
    end

    headers = src_opps.flat_map(&:keys).uniq
    headers << @@src_opp_id
    headers.sort!
    CSV.open(Rails.root.join('public',@@app_cred[:src_app],'opportunities.csv'),'wb+') do |csv|
      csv << headers
      src_opps.each do |opp|
        next if (dest_opps.include?(opp[@@src_opp_id]) || (@@con_rel[opp['ContactID']].nil? && @@comp_rel[opp['ContactID']].nil?))
        opp.each_key { |k| opp[k] = opp[k].to_time.strftime("%Y-%m-%d %H:%M:%S") if opp[k].is_a? XMLRPC::DateTime }
        opp.keys.each { |k| opp[rename_mapping[k]] = opp.delete(k) if rename_mapping[k]}
        opp['ContactID'] = @@con_rel[opp['ContactID']] || @@comp_rel[opp['ContactID']]
        opp['StageID'] = stage_rel[opp['StageID']]
        opp['UserID'] = @@user_rel[opp['UserID']] || 0
        opp[@@src_opp_id] = opp['Id']
        csv << opp.values_at(*headers) unless opp.nil?
      end
    end
  end

  def orders
    puts '| Generating Blank Orders CSV'

    puts '|| Source Data'
    initialize_infusionsoft(@@app_cred[:src_app], @@app_cred[:src_key])

    src_cfs = get_table('DataFormField')
    order_fields = FIELDS['Job'].map(&:clone)
    src_cfs.each { |cf| order_fields.push("_" + cf['Name']) if cf['FormId'] == -9 }
    src_orders = get_table('Job',order_fields)

    puts '|| Destination Data'
    initialize_infusionsoft(@@app_cred[:dest_app], @@app_cred[:dest_key])

    rename_mapping = {}
    src_cfs.each do |cf|
      if cf['FormId'] == -9
        field = create_custom_field(cf['Label'],0,'Job',DATATYPES[DATATYPE_IDS[cf['DataType']]]['dataType'])
        rename_mapping['_' + cf['Name']] = field['Name']
        Infusionsoft.data_update_custom_field(field['Id'],{ 'Values' => cf['Values'] }) if DATATYPES[DATATYPE_IDS[cf['DataType']]]['hasValues'] == 'yes'  && customfield['Values'] != nil
      end
    end

    dest_orders = get_table('Job',[@@src_order_id],{@@src_order_id => '_%'}).map { |j| j[@@src_order_id].to_i }

    headers = src_orders.flat_map(&:keys).uniq
    headers << @@src_order_id
    headers.sort!
    CSV.open(Rails.root.join('public',@@app_cred[:src_app],'orders.csv'),'wb+') do |csv|
      csv << headers
      src_orders.each do |o|
        next unless (@@con_rel[o['ContactId']]) || !((o['JobRecurringId'] == 0)) || dest_orders.exclude?(o['Id'])
        o['ProductId'] = @@prod_rel[o['ProductId']]
        next if o['JobRecurringId'] != 0
        o.each_key { |k| o[k] = o[k].to_time.strftime("%Y-%m-%d %H:%M:%S") if o[k].is_a? XMLRPC::DateTime }
        o.keys.each { |k| o[rename_mapping[k]] = o.delete(k) if rename_mapping[k]}
        o['DueDate'] ||= DateTime.now
        o['ContactId'] = @@con_rel[o['ContactId']]
        next if o['ContactId'].nil?
        o[@@src_order_id] = o['Id']
        csv << o.values_at(*headers) unless o.nil?
      end
    end
  end

  def subscriptions
    puts '| Generating Subscriptions CSV'

    puts '|| Source Data'
    initialize_infusionsoft(@@app_cred[:src_app], @@app_cred[:src_key])

    src_subs = get_table('RecurringOrder')
    src_ccs = get_table('CreditCard',['Id','ContactId','Last4','ExpirationMonth','ExpirationYear','NameOnCard'])
    src_cc_rel = {}
    src_ccs.each do |cc|
      src_cc_rel["#{cc['ContactId']} - #{cc['Last4']} - #{cc['ExpirationMonth']}/#{cc['ExpirationYear']} - #{cc['NameOnCard']}"] = cc['Id']
    end

    puts '|| Destination Data'
    initialize_infusionsoft(@@app_cred[:dest_app], @@app_cred[:dest_key])

    puts '||| Creating CC relationship'
    ccs_rel = {}
    get_table('CreditCard',['Id','ContactId','Last4','ExpirationMonth','ExpirationYear','NameOnCard']).each do |cc|
      ccs_rel[src_cc_rel["#{@@con_rel.key(cc['ContactId'])} - #{cc['Last4']} - #{cc['ExpirationMonth']}/#{cc['ExpirationYear']} - #{cc['NameOnCard']}"]] = cc['Id']
    end

    puts '||| Writing to CSV'
    headers = ['ContactId','SubscriptionPlanId','ProductId','ProgramId','CC1','PaymentGatewayId','Frequency','BillingCycle','BillingAmt','PromoCode','Status','StartDate','EndDate','ReasonStopped','PaidThruDate','NextBillDate','AutoCharge','MaxRetry','NumDaysBetweenRetry']
    CSV.open(Rails.root.join('public',@@app_cred[:src_app],'subscriptions.csv'),'wb+') do |csv|
      csv << headers
      src_subs.each do |s|
        s['ContactId'] = @@con_rel[s['ContactId']]
        next if s['ContactId'].nil?
        s['SubscriptionPlanId'] = @@sub_rel[s['SubscriptionPlanId']]
        s['ProductId'] = @@prod_rel[s['ProductId']]
        s['ProgramId'] = @@sub_rel[s['ProgramId']]
        s['CC1'] = !ccs_rel[s['CC1']].nil? ? ccs_rel[s['CC1']] : ccs_rel[s['CC2']]
        s['CC1'] = 0 if s['CC1'].nil?
        s['PaymentGatewayId'] = 'SEE DESTINATION APP'
        s['AutoCharge'] = s['AutoCharge'] == 1 ? 'Yes' : 'No'

        s['NextBillDate'] = s['NextBillDate'].to_time

        if s['PaidThruDate'].nil?
          case s['BillingCycle']
          when '1'
            s['PaidThruDate'] = s['NextBillDate'] - 1.year
          when '2'
            s['PaidThruDate'] = s['NextBillDate'] - 1.month
          when '3'
            s['PaidThruDate'] = s['NextBillDate'] - 1.week
          when '6'
            s['PaidThruDate'] = s['NextBillDate'] - 1.day
          end
        end

        s['PaidThruDate'] = s['PaidThruDate'].to_time
        cut_off_date = Date.parse(params[:subscription_date])
        if s['NextBillDate'].to_time <= cut_off_date
          case s['BillingCycle']
          when '1'
            s['PaidThruDate'] = s['PaidThruDate'] + 1.year
          when '2'
            s['PaidThruDate'] = s['PaidThruDate'] + 1.month
          when '3'
            s['PaidThruDate'] = s['PaidThruDate'] + 1.week
          when '6'
            while s['PaidThruDate'] <= cut_off_date
              s['PaidThruDate'] = s['PaidThruDate'] + 1.day
            end
          end
        end

        if s['Status'] == 'Inactive'
          case s['BillingCycle']
          when '1'
            s['PaidThruDate'] = s['PaidThruDate'] - 1.year
          when '2'
            s['PaidThruDate'] = s['PaidThruDate'] - 1.month
          when '3'
            s['PaidThruDate'] = s['PaidThruDate'] - 1.week
          when '6'
            s['PaidThruDate'] = s['PaidThruDate'] - 1.day
          end
        end

        s['PaidThruDate'] = s['PaidThruDate'].strftime("%Y-%m-%d %H:%M:%S") unless s['PaidThruDate'].nil?
        s.each_key { |k| next if s[k].nil?; s[k] = s[k].to_time.strftime("%Y-%m-%d %H:%M:%S") if s[k].is_a? XMLRPC::DateTime }
        csv << s.values_at(*headers) unless s.nil?
      end
    end
  end

#===============================================================================

  def step3
    initialize_infusionsoft(@@app_cred[:dest_app], @@app_cred[:dest_key])

    @@order_rel = {}
    get_table('Job',['Id',@@src_order_id],{@@src_order_id => '_%'}).each { |order| @@order_rel[order[@@src_order_id].to_i] = order['Id'] }

    order_items if params[:order_items][:checkbox] == 'true'
    payments if params[:payments][:checkbox] == 'true'
  end

  def order_items
    puts '| Generating Order Items CSV'

    puts '|| Source Data'
    initialize_infusionsoft(@@app_cred[:src_app], @@app_cred[:src_key])

    src_oitems = get_table('OrderItem')
    src_iitems = get_table('InvoiceItem')
    invamt_by_id = {}
    src_iitems.each do |ii|
      invamt_by_id[ii['OrderItemId']] = ii['InvoiceAmt']
    end

    puts '|| Destination Data'
    initialize_infusionsoft(@@app_cred[:dest_app], @@app_cred[:dest_key])

        puts '||| Writing to CSV'
    headers = ['OrderId','ProductId','ItemType','ItemName','ItemDescription','Qty','PricePerUnit','Notes']
    CSV.open(Rails.root.join('public',@@app_cred[:src_app],'order_items.csv'),'wb+') do |csv|
      csv << headers
      src_oitems.each do |oi|
        oi['OrderId'] = @@order_rel[oi['OrderId']]
        next if oi['OrderId'].nil?
        oi['ProductId'] = @@prod_rel[oi['ProductId']]
        next if oi['ProductId'].nil?
        oi['PricePerUnit'] = invamt_by_id[oi['Id']] / oi['Qty']
        csv << oi.values_at(*headers) unless oi.nil?
      end
    end

  end

  def payments
    puts '| Generating Payments CSV'

    puts '|| Source Data'
    initialize_infusionsoft(@@app_cred[:src_app], @@app_cred[:src_key])

    src_inv = get_table('Invoice')
    src_payments = get_table('Payment')
    src_inv_rel = {}
    src_inv.each do |i|
      src_inv_rel[i['JobId']] = i['Id']
    end

    puts '|| Destination Data'
    initialize_infusionsoft(@@app_cred[:dest_app], @@app_cred[:dest_key])

    dest_inv = get_table('Invoice')
    dest_inv_rel = {}
    dest_inv.each do |i|
      dest_inv_rel[i['JobId']] = i['Id']
    end

    inv_rel = {}
    src_inv_rel.each do |k,v|
      inv_rel[v] = dest_inv_rel[@@order_rel[k]]
    end

    puts '||| Writing to CSV'
    headers = ['InvoiceId','PayDate','PayType','PayAmt','PayNote']
    CSV.open(Rails.root.join('public',@@app_cred[:src_app],'payments.csv'),'wb+') do |csv|
      csv << headers
      src_payments.each do |pay|
        pay['InvoiceId'] = inv_rel[pay['InvoiceId'].to_i]
        next if pay['InvoiceId'].nil?
        pay.each_key { |k| pay[k] = pay[k].to_time.strftime("%Y-%m-%d %H:%M:%S") if pay[k].is_a? XMLRPC::DateTime }
        csv << pay.values_at(*headers) unless pay.nil?
      end
    end
  end

end
