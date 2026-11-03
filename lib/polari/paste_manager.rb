# frozen_string_literal: true

require 'adwaita'
require_relative 'utils'

module Polari
  # PasteManager uploads what the user pasted or dropped into the entry: text
  # goes to paste.gnome.org, an image to imgur, and a file to whichever of the
  # two fits its content type.
  #
  # Ported from src/pasteManager.js. The content a caller hands over is a
  # String for text, a Gio::File for a file, or the PNG bytes of an image —
  # upstream passes a GdkPixbuf there and encodes it on the way out, which is
  # the one step this port asks its caller to have done already, since the
  # pixbuf bindings differ.
  class PasteManager
    class UnhandledContent < StandardError; end

    def paste_content(content, title)
      case content
      when String then Utils.gpaste(content, title)
      when Gio::File then paste_file(content, title)
      else paste_image(content, title)
      end
    end

    private

      def paste_image(content, title)
        if content.respond_to?(:save_to_buffer)
          Utils.imgur_paste(content.save_to_buffer('png'), title)
        else
          raise UnhandledContent, "Unhandled content type #{content.class}"
        end
      end

      def paste_file(file, title)
        content_type = file.query_info('standard::content-type', :none).content_type

        if Gio.content_type_is_a(content_type, 'text/plain')
          Utils.gpaste(file.load_contents.first, title)
        elsif Gio.content_type_is_a(content_type, 'image/*')
          Utils.imgur_paste(file.load_contents.first, title)
        else
          raise UnhandledContent, "Unhandled content type #{content_type}"
        end
      end
  end

  # DropTargets adds the drop handling upstream puts in its DropTargetIface:
  # text, images and files dropped on the chat view or the entry end up in the
  # paste confirmation.
  #
  # Ported from the DropTargetIface class in src/pasteManager.js. A GObject
  # interface cannot be declared from Ruby, so this is a module the widgets
  # extend, and the three signals it would carry (::text-dropped,
  # ::image-dropped, ::file-dropped) are the three callbacks passed in.
  module DropTargets
    DROP_MIME_TYPES = ['text/plain', 'text/uri-list', 'image/png', 'image/jpeg'].freeze

    def add_drop_targets(widget, on_text: nil, on_file: nil)
      add_text_drop_target(widget, on_text)
      add_file_drop_target(widget, on_file)
    end

    private

      def add_text_drop_target(widget, on_text)
        Gtk::DropTarget.new(String, :copy).tap do |target|
          target.signal_connect('drop') do |_t, value, _x, _y|
            if can_drop? && on_text
              on_text.call(value)
            end
            can_drop?
          end
          widget.add_controller(target)
        end
      end

      def add_file_drop_target(widget, on_file)
        Gtk::DropTarget.new(Gio::File, :copy).tap do |target|
          target.signal_connect('drop') do |_t, value, _x, _y|
            if can_drop? && on_file && handle_file?(value)
              on_file.call(value)
            end
            can_drop?
          end
          widget.add_controller(target)
        end
      end

      # Only the content types the paste services can take are accepted,
      # which is what upstream's _canHandleFile() checks.
      def handle_file?(file)
        content_type = file.query_info('standard::content-type', :none).content_type
        DROP_MIME_TYPES.any? { |mime| Gio.content_type_is_a(content_type, mime) }
      rescue StandardError => e
        warn "Failed to determine content type: #{e.message}"
        false
      end
  end
end
