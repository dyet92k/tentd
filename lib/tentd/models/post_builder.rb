module TentD
  module Model

    module PostBuilder
      extend self

      CreateFailure = Post::CreateFailure

      def build_attributes(env, options = {})
        data = env['data']
        current_user = env['current_user']
        type, base_type = Type.find_or_create(data['type'])

        unless type
          raise CreateFailure.new("Invalid type: #{data['type'].inspect}")
        end

        received_at_timestamp = TentD::Utils.timestamp
        published_at_timestamp = (data['published_at'] || received_at_timestamp).to_i

        attrs = {
          :user_id => current_user.id,

          :type => type.type,
          :type_id => type.id,
          :type_base_id => base_type.id,

          :version_published_at => published_at_timestamp,
          :version_received_at => received_at_timestamp,
          :published_at => published_at_timestamp,
          :received_at => received_at_timestamp,

          :content => data['content'],
        }

        if options[:import]
          attrs.merge!(
            :entity_id => Entity.first_or_create(data['entity']).id,
            :entity => data['entity']
          )
        elsif options[:entity]
          attrs.merge!(
            :entity_id => Entity.first_or_create(options[:entity]).id,
            :entity => options[:entity]
          )
        else
          attrs.merge!(
            :entity_id => current_user.entity_id,
            :entity => current_user.entity,
          )
        end

        if options[:public_id]
          attrs[:public_id] = options[:public_id]
        end

        if data['version'] && Array === data['version']['parents']
          attrs[:version_parents] = data['version']['parents']
          attrs[:version_parents].each_with_index do |item, index|
            unless item['version']
              raise CreateFailure.new("/version/parents/#{index}/version is required")
            end

            unless item['post']
              raise CreateFailure.new("/version/parents/#{index}/post is required")
            end
          end
        elsif options[:version]
          unless options[:notification]
            raise CreateFailure.new("Parent version not specified")
          end
        end

        if TentType.new(attrs[:type]).base == %(https://tent.io/types/meta)
          # meta post is always public
          attrs[:public] = true
        else
          if Hash === data['permissions']
            if data['permissions']['public'] == true
              attrs[:public] = true
            else
              attrs[:public] = false

              if Array === data['permissions']['entities']
                attrs[:permissions_entities] = data['permissions']['entities']
              end
            end
          else
            attrs[:public] = true
          end
        end

        if Array === data['mentions'] && data['mentions'].any?
          attrs[:mentions] = data['mentions'].map do |m|
            m['entity'] = attrs[:entity] unless m.has_key?('entity')
            m
          end
        end

        if Array === data['refs'] && data['refs'].any?
          attrs[:refs] = data['refs'].map do |ref|
            ref['entity'] = attrs[:entity] unless ref.has_key?('entity')
            ref
          end
        end

        if options[:notification]
          attrs[:attachments] = data['attachments'] if Array === data['attachments']
        else
          if Array === data['attachments']
            data['attachments'] = data['attachments'].inject([]) do |memo, attachment|
              next memo unless attachment.has_key?('digest')
              if attachment['model'] = Attachment.where(:digest => attachment['digest']).first
                memo << attachment
              end
              memo
            end

            attrs[:attachments] = data['attachments'].map do |attachment|
              {
                :digest => attachment['digest'],
                :size => attachment['model'].size,
                :name => attachment['name'],
                :category => attachment['category'],
                :content_type => attachment['content_type']
              }
            end
          end

          if Array === env['attachments']
            attrs[:attachments] = env['attachments'].inject(attrs[:attachments] || Array.new) do |memo, attachment|
              memo << {
                :digest => TentD::Utils.hex_digest(attachment[:tempfile]),
                :size => attachment[:tempfile].size,
                :name => attachment[:name],
                :category => attachment[:category],
                :content_type => attachment[:content_type]
              }
              memo
            end
          end
        end

        attrs
      end

      def create_delete_post(post)
        create_from_env(
          'current_user' => post.user,
          'data' => {
            'type' => 'https://tent.io/types/delete/v0#',
            'refs' => [
              { 'entity' => post.entity, 'post' => post.public_id }
            ]
          }
        )
      end

      def create_from_env(env, options = {})
        attrs = build_attributes(env, options)

        if TentType.new(env['data']['type']).base == %(https://tent.io/types/subscription)
          if options[:notification]
            subscription = Subscription.create_from_notification(env['current_user'], attrs, env['current_auth.resource'])
            post = subscription.post
          else
            subscription = Subscription.find_or_create(attrs)
            post = subscription.post

            if subscription.deliver == false
              # this will happen as part of the relaitonship init job
              options[:deliver_notification] = false
            end
          end
        else
          post = Post.create(attrs)
        end

        if Array === env['data']['mentions']
          post.create_mentions(env['data']['mentions'])
        end

        unless options[:notification]
          if Array === env['data']['attachments']
            env['data']['attachments'].each do |attachment|
              PostsAttachment.create(
                :attachment_id => attachment['model'].id,
                :content_type => attachment['content_type'],
                :post_id => post.id
              )
            end
          end

          if Array === env['attachments']
            post.create_attachments(env['attachments'])
          end
        end

        if Array === attrs[:version_parents]
          post.create_version_parents(attrs[:version_parents])
        end

        if !options[:notification] && !options[:import] && options[:deliver_notification] != false
          post.queue_delivery
        end

        post
      end

      def create_attachments(post, attachments)
        attachments.each_with_index do |attachment, index|
          data = attachment[:tempfile].read
          attachment[:tempfile].rewind

          PostsAttachment.create(
            :attachment_id => Attachment.find_or_create(
              TentD::Utils::Hash.slice(post.attachments[index], 'digest', 'size').merge(:data => data)
            ).id,
            :post_id => post.id,
            :content_type => attachment[:content_type]
          )
        end
      end

      def create_mentions(post, mentions)
        mentions.map do |mention|
          mention_attrs = {
            :user_id => post.user_id,
            :post_id => post.id
          }

          if mention['entity']
            mention_attrs[:entity_id] = Entity.first_or_create(mention['entity']).id
            mention_attrs[:entity] = mention['entity']
          else
            mention_attrs[:entity_id] = post.entity_id
            mention_attrs[:entity] = post.entity
          end

          if mention['type']
            mention_attrs[:type_id] = Type.find_or_create_full(mention['type']).id
            mention_attrs[:type] = mention['type']
          end

          mention_attrs[:post] = mention['post'] if mention.has_key?('post')
          mention_attrs[:public] = mention['public'] if mention.has_key?('public')

          Mention.create(mention_attrs)
        end
      end

      def create_version_parents(post, version_parents)
        version_parents.each do |item|
          item['post'] ||= post.public_id
          _parent = Post.where(:user_id => post.user_id, :public_id => item['post'], :version => item['version']).first
          Parent.create(
            :post_id => post.id,
            :parent_post_id => _parent ? _parent.id : nil,
            :version => item['version'],
            :post => item['post']
          )
        end
      end

    end

  end
end
