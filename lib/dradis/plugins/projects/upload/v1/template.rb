module Dradis::Plugins::Projects::Upload::V1
  class Template
    attr_accessor :logger

    def initialize(args={})
      @logger = args.fetch(:logger, Rails.logger)
    end

    def parse(template)
      # we need this to be able to convert from old category_id to the new
      # category_id once the categories are added to the DB (the ID may have
      # changed)
      category_lookup = {}
      # the same applies to Nodes (think parent_id)
      node_lookup = {}
      # and to issues
      issue_lookup = {}

      # evidence is parsed when nodes are parsed, but cannot be saved until issues
      # have been created. Therefore, parse evidence into arrays until time for
      # creation
      evidence_array = []

      # likewise we also need to hold on to the XML about evidence activities
      # until after the evidence has been saved
      evidence_activity_xml_array = []

      # all children nodes, we will need to find the new ID of their parents
      orphan_nodes = []

      # if the note has an attachment screenshot (i.e. !.../nodes/i/attachments/...!)
      # we will fix the URL to point to the new Node ID.
      #
      # WARNING: we need a lookup table because one note may be referencing a
      # different (yet unprocessed) node's attachments.
      attachment_notes = []

      # go through the categories, keep a translation table between the old
      # category id and the new ones so we know to which category we should
      # assign our notes
      template.xpath('dradis-template/categories/category').each do |xml_category|
        old_id   = xml_category.at_xpath('id').text.strip
        name     = xml_category.at_xpath('name').text.strip
        category = nil

        # Prevent creating duplicate categories
        logger.info { "Looking for category: #{name}" }
        category = Category.find_or_create_by!(name: name)
        category_lookup[old_id] = category.id
      end


      # ------------------------------------------------------------------- Nodes
      # Re generate the Node tree structure
      template.xpath('dradis-template/nodes/node').each do |xml_node|
        element   = xml_node.at_xpath('type-id')
        type_id   = element.text.nil? ? nil : element.text.strip
        label     = xml_node.at_xpath('label').text.strip
        element   = xml_node.at_xpath('parent-id')
        parent_id = element.text.nil? ? nil : element.text.strip

        # Node positions
        element  = xml_node.at_xpath('position')
        position = (element && !element.text.nil?) ? element.text.strip : nil

        # Node properties
        element    = xml_node.at_xpath('properties')
        properties = (element && !element.text.blank?) ? element.text.strip : nil

        created_at = xml_node.at_xpath('created-at')
        updated_at = xml_node.at_xpath('updated-at')

        logger.info { "New node detected: #{label}, parent_id: #{parent_id}, type_id: #{type_id}" }

        # There is one exception to the rule, the Configuration.uploadsNode node,
        # it does not make sense to have more than one of this nodes, in any
        # given tree
        node = nil
        note = nil
        evidence = nil
        if (label == Configuration.plugin_uploads_node)
          node = Node.create_with(type_id: type_id, parent_id: parent_id).
                  find_or_create_by!(label: label)
        else
          node = Node.create!(
                   type_id:   type_id,
                   label:     label,
                   parent_id: parent_id,
                   position:  position
                 )
        end

        if properties
          node.raw_properties = properties
        end

        node.update_attribute(:created_at, created_at.text.strip) if created_at
        node.update_attribute(:updated_at, updated_at.text.strip) if updated_at

        return false unless validate_and_save(node)
        return false unless create_activities(node, xml_node)

        xml_node.xpath('notes/note').each do |xml_note|

          if xml_note.at_xpath('author') != nil
            old_id = xml_note.at_xpath('category-id').text.strip
            new_id = category_lookup[old_id]

            created_at  = xml_note.at_xpath('created-at')
            updated_at  = xml_note.at_xpath('updated-at')

            logger.info { "Note category rewrite, used to be #{old_id}, now is #{new_id}" }
            note = Note.create!(
                     author:      xml_note.at_xpath('author').text.strip,
                     node_id:     node.id,
                     category_id: new_id,
                     text:        xml_note.at_xpath('text').text
                   )

            note.update_attribute(:created_at, created_at.text.strip) if created_at
            note.update_attribute(:updated_at, updated_at.text.strip) if updated_at

            return false unless validate_and_save(note)

            if note.text =~ %r{^!(.*)/nodes/(\d+)/attachments/(.+)!$}
              attachment_notes << note
            end

            return false unless create_activities(note, xml_note)

            logger.info { "\tNew note added detected." }
          end
        end

        # Create array of evidence from xml input. Cannot store in DB until we
        # have a new issue id
        xml_node.xpath('evidence/evidence').each do |xml_evidence|
          if xml_evidence.at_xpath('author') != nil
            created_at  = xml_evidence.at_xpath('created-at')
            updated_at  = xml_evidence.at_xpath('updated-at')

            evidence = Evidence.new(
                         author:   xml_evidence.at_xpath('author').text.strip,
                         node_id:  node.id,
                         content:  xml_evidence.at_xpath('content').text,
                         issue_id: xml_evidence.at_xpath('issue-id').text.strip
                       )

            evidence.update_attribute(:created_at, created_at.text.strip) if created_at
            evidence.update_attribute(:updated_at, updated_at.text.strip) if updated_at
            evidence_array << evidence

            evidence_activity_xml_array << xml_evidence.xpath("activities/activity")

            logger.info { "\tNew evidence added." }
          end
        end

        # keep track of reassigned ids
        node_lookup[xml_node.at_xpath('id').text.strip] = node.id

        if node.parent_id != nil
          # keep track of orphaned nodes
          orphan_nodes << node
        end
      end


      # ------------------------------------------------------------------- Issues
      issue = nil
      issue_category = Category.issue
      issue_library  = Node.issue_library
      # go through the issues, keep a translation table between the old
      # issue id and the new ones. This is important for importing evidence
      # Will need to adjust node ID after generating node structure
      template.xpath('dradis-template/issues/issue').each do |xml_issue|
        old_id = xml_issue.at_xpath('id').text.strip

        # TODO: Need to find some way of checking for dups
        # May be combination of text, category_id and created_at
        issue = Issue.new
        issue.author   = xml_issue.at_xpath('author').text.strip
        issue.text     = xml_issue.at_xpath('text').text
        issue.node     = issue_library
        issue.category = issue_category

        return false unless validate_and_save(issue)

        return false unless create_activities(issue, xml_issue)

        if issue.text =~ %r{^!(.*)/nodes/(\d+)/attachments/(.+)!$}
          attachment_notes << issue
        end

        issue_lookup[old_id] = issue.id
        logger.info{ "New issue detected: #{issue.title}" }
      end

      # ----------------------------------------------------------- Methodologies
      methodology_category = Category.default
      methodology_library  = Node.methodology_library
      template.xpath('dradis-template/methodologies/methodology').each do |xml_methodology|
        # FIXME: this is wrong in a few levels, we should be able to save a
        # Methodology instance calling .save() but the current implementation
        # of the model would consider this a 'methodology template' and not an
        # instance.
        #
        # Also, methodology notes don't have a valid author, see
        # MethodologiesController#create action (i.e. 'methodology builder' is
        # used).
        Note.create!(
          author:      'methodology importer',
          node_id:     methodology_library.id,
          category_id: methodology_category.id,
          text:        xml_methodology.at_xpath('text').text
        )
      end

      # -------------------------------------------------------------------- Tags
      template.xpath('dradis-template/tags/tag').each do |xml_tag|
        name = xml_tag.at_xpath('name').text()
        tag  = Tag.find_or_create_by!(name: name)
        @logger.info { "New tag detected: #{name}" }

        xml_tag.xpath('./taggings/tagging').each do |xml_tagging|
          old_taggable_id = xml_tagging.at_xpath('taggable-id').text()
          taggable_type   = xml_tagging.at_xpath('taggable-type').text()

          new_taggable_id = case taggable_type
                            when 'Note'
                              issue_lookup[old_taggable_id]
                            end

          Tagging.create! tag: tag, taggable_id: new_taggable_id, taggable_type: taggable_type
        end
      end

      # ----------------------------------------------------------------- Wrap up

      logger.info { "Wrapping up..." }

      # Save the Evidence instance to the DB now that we have populated Issues
      # the original issues
      evidence_array.each_with_index do |evidence, i|
        logger.info { "Setting issue_id for evidence" }
        evidence.issue_id = issue_lookup[evidence.issue_id.to_s]

        new_content      = evidence.content.gsub(%r{^!(.*)/nodes/(\d+)/attachments/(.+)!$}) do |_|
          "!%s/nodes/%d/attachments/%s!" % [$1, node_lookup[$2], $3]
        end
        evidence.content = new_content

        return false unless validate_and_save(evidence)

        evidence_activity_xml_array[i].each do |xml_activity|
          return false unless create_activity(evidence, xml_activity)
        end
      end

      # Fix relationships between nodes to ensure parents and childrens match
      # with the new assigned :ids
      orphan_nodes.each do |node|
        logger.info { "Finding parent for orphaned node: #{node.label}. Former parent was #{node.parent_id}" }
        node.parent_id = node_lookup[node.parent_id.to_s]
        return false unless validate_and_save(node)
      end

      # Adjust attachment URLs for new Node IDs
      attachment_notes.each do |note|
        @logger.info{ "Adjusting screenshot URLs: Note ##{note.id}" }
        new_text = note.text.gsub(%r{^!(.*)/nodes/(\d+)/attachments/(.+)!$}) do |_|
          "!%s/nodes/%d/attachments/%s!" % [$1, node_lookup[$2], $3]
        end
        note.text = new_text
        return false unless validate_and_save(note)
      end

      return node_lookup
    end

    private

    def create_activities(trackable, xml_trackable)
      xml_trackable.xpath('activities/activity').each do |xml_activity|
        # if 'validate_and_save(activity)' returns false, it needs
        # to bubble up to the 'import' method so we can stop execution
        return false unless create_activity(trackable, xml_activity)
      end
    end

    def create_activity(trackable, xml_activity)
      activity = trackable.activities.new(
        action:     xml_activity.at_xpath("action").text,
        created_at: Time.at(xml_activity.at_xpath("created_at").text.to_i)
      )

      set_activity_user(activity, xml_activity.at_xpath("user_email").text)

      validate_and_save(activity)
    end

    def set_activity_user(activity, email)
      if Activity.column_names.include?('user')
        activity.user = email
      else
        activity.user_id = user_id_for_email(email)
      end
    end

    # Cache users to cut down on excess SQL requests
    def user_id_for_email(email)
      return -1 if email.blank?
      @users ||= begin
        User.select([:id, :email]).all.each_with_object({}) do |user, hash|
          hash[user.email] = user.id
        end
      end
      @users[email] || -1
    end

    def validate_and_save(instance)
      if instance.save
        return true
      else
        @logger.info{ "Malformed #{ instance.class.name } detected: #{ instance.errors.full_messages }" }
        return false
      end
    end
  end
end
