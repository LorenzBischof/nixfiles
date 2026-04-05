{
  button,
  light,
  boolean ? "input_boolean.light_hold",
  brightnessThreshold ? 130,
  brightnessStepPct ? 7,
  transitionStepLength ? 0.3,
}:
{
  id = "${button}${light}";
  alias = "ZHA Light Button - ${light} - ${button}";
  mode = "parallel";
  max_exceeded = "silent";
  triggers = [
    {
      platform = "event";
      event_type = "zha_event";
      event_data.device_id = button;
    }
  ];
  actions = [
    {
      variables = {
        brightness_step_pct_positive = brightnessStepPct;
        brightness_step_pct_negative = brightnessStepPct * -1;
        inherit light boolean;
        max_brightness = 255;
        click_type = "{{ trigger.event.data.args.click_type }}";
        command = "{{ trigger.event.data.command }}";
      };
    }
    {
      variables = {
        min_kelvin = "{{ state_attr(light, 'min_color_temp_kelvin') }}";
        max_kelvin = "{{ state_attr(light, 'max_color_temp_kelvin') }}";
        initial_kelvin = "{{ state_attr(light, 'color_temp_kelvin') | float(1500) }}";
        initial_brightness = "{{ state_attr(light, 'brightness') | float(0.0) }}";
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
              service = "input_boolean.turn_on";
              target.entity_id = boolean;
            }
            {
              choose = [
                {
                  conditions = [
                    {
                      condition = "numeric_state";
                      entity_id = light;
                      attribute = "brightness";
                      above = brightnessThreshold;
                    }
                  ];
                  sequence = [
                    {
                      repeat = {
                        while = [
                          {
                            condition = "state";
                            entity_id = boolean;
                            state = "on";
                          }
                          "{{ repeat.index <= 20 }}"
                        ];
                        sequence = [
                          {
                            service = "light.turn_on";
                            data = {
                              transition = transitionStepLength;
                              brightness_step_pct = "{{ brightness_step_pct_negative }}";
                              color_temp_kelvin = "{{ (min_kelvin + ((initial_kelvin - min_kelvin) * (state_attr(light, 'brightness') / initial_brightness))) | int }}";
                            };
                            entity_id = light;
                          }
                          {
                            delay.seconds = transitionStepLength;
                          }
                        ];
                      };
                    }
                  ];
                }
              ];
              default = [
                {
                  repeat = {
                    while = [
                      {
                        condition = "state";
                        entity_id = boolean;
                        state = "on";
                      }
                      "{{ repeat.index <= 20 }}"
                    ];
                    sequence = [
                      {
                        service = "light.turn_on";
                        data = {
                          transition = transitionStepLength;
                          brightness_step_pct = "{{ brightness_step_pct_positive }}";
                          color_temp_kelvin = "{{ (initial_kelvin + ((max_kelvin - initial_kelvin) * ((state_attr(light, 'brightness') | float(0.0) - initial_brightness) / (max_brightness - initial_brightness)))) | int }}";
                        };
                        entity_id = light;
                      }
                      {
                        delay.seconds = transitionStepLength;
                      }
                    ];
                  };
                }
              ];
            }
          ];
        }
        {
          conditions = [
            "{{ command == \"release\" }}"
          ];
          sequence = [
            {
              service = "input_boolean.turn_off";
              target.entity_id = boolean;
            }
          ];
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
