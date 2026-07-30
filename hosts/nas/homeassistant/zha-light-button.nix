{
  button,
  light,
  # Holding the button dims down above this perceived level, and up below it
  # (or from off). This is deliberately on the same gamma-corrected scale as
  # the ramp; 50% perceived brightness is only about 55 on HA's 0-255 scale.
  directionSwitchPct ? 50,
  # Change in *perceived* brightness per step, in percent. A full sweep takes
  # 100 / brightnessStepPct steps.
  brightnessStepPct ? 7,
  # The dark end of HA's raw 1-255 brightness range. Dimming down stops here
  # instead of switching the light off, and dimming up from off starts here.
  minBrightness ? 1,
  # Perception of brightness is roughly the 2.2nd root of emitted light, so a
  # ramp that is linear in Home Assistant's 0-255 brightness races through the
  # dim end: from off, one linear step already looks like a third of the way
  # up. Ramping a perceived level through this exponent keeps the steps even.
  # Set to 1 for a plain linear ramp.
  gamma ? 2.2,
  # Some Zigbee lights advertise a much wider range than is useful in a room
  # (the living-room Hue reports 1000-20000K). Keep the ramp within deliberate
  # warm/cool endpoints, clamped to what the entity actually supports.
  warmKelvin ? 2000,
  coolKelvin ? 6500,
  transitionStepLength ? 0.3,
  # Safety net: a lost "release" event must not leave the loop spinning.
  maxSteps ? 20,
}:
{
  id = "${button}${light}";
  alias = "ZHA Light Button - ${light} - ${button}";
  # A release restarts (and therefore cancels) the active hold run. This gives
  # each button exactly one ramp owner without a shared input_boolean that can
  # be cleared by another button.
  mode = "restart";
  max_exceeded = "silent";
  # The button also emits attribute_updated events around every interaction.
  # Do not let those no-op events start/restart this automation.
  triggers =
    map
      (command: {
        platform = "event";
        event_type = "zha_event";
        event_data = {
          inherit command;
          device_id = button;
        };
      })
      [
        "hold"
        "release"
        "click"
      ];
  actions = [
    {
      variables = {
        inherit light;
        click_type = "{{ trigger.event.data.args.click_type | default('') }}";
        command = "{{ trigger.event.data.command }}";
        step = brightnessStepPct / 100.0;
        floor_brightness = minBrightness;
        floor_level = "{{ (${toString minBrightness} / 255) ** (1 / ${toString gamma}) }}";
        direction_threshold = "{{ (255 * (${toString directionSwitchPct} / 100) ** ${toString gamma}) | round | int }}";
      };
    }
    {
      # Each variables: block only sees the ones defined in *earlier* actions,
      # so anything built on top of another variable needs its own block.
      variables = {
        supported_min_kelvin = "{{ state_attr(light, 'min_color_temp_kelvin') }}";
        supported_max_kelvin = "{{ state_attr(light, 'max_color_temp_kelvin') }}";
      };
    }
    {
      variables = {
        warm_kelvin = "{{ [[${toString warmKelvin}, supported_min_kelvin] | max, supported_max_kelvin] | min }}";
        cool_kelvin = "{{ [[${toString coolKelvin}, supported_min_kelvin] | max, supported_max_kelvin] | min }}";
      };
    }
    {
      variables = {
        # Do not resume from attributes retained by an integration while the
        # light is off: a hold must always turn on at the warm, dark endpoint.
        from_brightness = "{{ 0 if is_state(light, 'off') else state_attr(light, 'brightness') | float(0.0) }}";
        from_kelvin = "{{ warm_kelvin if is_state(light, 'off') else state_attr(light, 'color_temp_kelvin') | float(warm_kelvin) }}";
      };
    }
    {
      # Dimming walks a straight line from where the light is right now to one
      # end of its range: dim and warm, or bright and cool. Both endpoints are
      # captured once, before the loop, so each step is a plain interpolation
      # on repeat.index. Reading the light's live brightness inside the loop
      # does not work: some lights (seen on LIFX) echo back a stale brightness
      # mid-transition, which desynchronised brightness from colour.
      variables = {
        # 0 is off and 1 is full, on the perceived scale the ramp runs on.
        from_level = "{{ (from_brightness / 255) ** (1 / ${toString gamma}) }}";
        color_from_brightness = "{{ [from_brightness, floor_brightness] | max }}";
        to_brightness = "{{ floor_brightness if from_brightness > direction_threshold else 255 }}";
        to_level = "{{ floor_level if from_brightness > direction_threshold else 1 }}";
        to_kelvin = "{{ warm_kelvin if from_brightness > direction_threshold else cool_kelvin }}";
      };
    }
    {
      choose = [
        {
          conditions = [
            "{{ command == \"hold\" }}"
          ];
          sequence = [
            {
              repeat = {
                while = [
                  "{{ repeat.index <= ${toString maxSteps} }}"
                  # Stop after commanding the endpoint once instead of
                  # repeatedly filling the light's command queue.
                  "{{ (repeat.index - 1) * step < (to_level - from_level) | abs }}"
                ];
                sequence = [
                  {
                    # 0 at the light's starting point, 1 once it has travelled
                    # the whole way to the endpoint.
                    variables.progress = ''
                      {%- set span = [(to_level - from_level) | abs, 0.01] | max -%}
                      {{ [repeat.index * step / span, 1] | min }}
                    '';
                  }
                  {
                    variables.level = "{{ from_level + (to_level - from_level) * progress }}";
                  }
                  {
                    # A light that starts off sits below the floor, so the
                    # first step clamps to it rather than commanding 0, which
                    # Home Assistant would turn into a light.turn_off.
                    variables.brightness = "{{ [(255 * level ** ${toString gamma}) | round | int, floor_brightness] | max }}";
                  }
                  {
                    # Colour follows the raw emitted-brightness fraction, not
                    # the perceived-light fraction. This keeps the dim end
                    # warm instead of racing towards blue-white while the raw
                    # brightness is still in the single digits.
                    variables.color_progress = ''
                      {%- set span = to_brightness - color_from_brightness -%}
                      {{ 1 if span == 0 else [[(brightness - color_from_brightness) / span, 0] | max, 1] | min }}
                    '';
                  }
                  {
                    service = "light.turn_on";
                    target.entity_id = light;
                    data = {
                      # With a transition, an off light can briefly illuminate
                      # using its previous colour before reaching warm_kelvin.
                      transition = "{{ 0 if from_brightness == 0 and repeat.index == 1 else ${toString transitionStepLength} }}";
                      brightness = "{{ brightness | int }}";
                      color_temp_kelvin = "{{ (from_kelvin + (to_kelvin - from_kelvin) * color_progress) | int }}";
                    };
                  }
                  {
                    delay.seconds = transitionStepLength;
                  }
                ];
              };
            }
          ];
        }
        {
          conditions = [
            "{{ command == \"release\" }}"
          ];
          # In restart mode, reaching this no-op branch has already cancelled
          # the hold run.
          sequence = [ ];
        }
        {
          conditions = [
            "{{ click_type == \"single\" }}"
          ];
          sequence = [
            {
              service = "light.toggle";
              data.entity_id = light;
              data.transition = 0.3;
            }
          ];
        }
        {
          conditions = [
            "{{ click_type == \"double\" }}"
          ];
          sequence = [
            {
              service = "light.turn_on";
              data = {
                entity_id = light;
                brightness_pct = 100;
                color_temp_kelvin = 4000;
              };
            }
          ];
        }
      ];
    }
  ];
}
