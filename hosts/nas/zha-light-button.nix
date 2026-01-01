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
        min_mireds = "{{ state_attr(light, 'min_mireds') }}";
        max_mireds = "{{ state_attr(light, 'max_mireds') }}";
        initial_mireds = "{{ state_attr(light, 'color_temp') | float(666) }}";
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
                              color_temp = "{{ max_mireds - ((max_mireds - initial_mireds) * (state_attr(light, 'brightness') / initial_brightness)) | int }}";
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
                          color_temp = "{{ initial_mireds - ((initial_mireds - min_mireds) * ((state_attr(light, 'brightness') | float(0.0) - initial_brightness) / (max_brightness - initial_brightness))) | int }}";
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
                color_temp = 250;
              };
            }
          ];
        }
      ];
    }
  ];
}
