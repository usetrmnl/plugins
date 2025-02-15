module Plugins
  class Routes < Base
    def locals
      { routes:, origin:, destination:, last_updated: }
    end

    private

    def routes
      [
        {
          name: "Via N234",
          distance: "13.2 km",
          duration: "17 min",
          is_fastest: true,
          travel_mode: '🚘'
        },
        {
          name: "via R. São Romão/N234 and N234",
          distance: "15.8 km",
          duration: "18 min",
          is_fastest: false,
          travel_mode: '🚘'
        },
        {
          name: "via CM1037",
          distance: "12.9 km",
          duration: "18 min",
          is_fastest: false,
          travel_mode: '🚘'
        }
      ]
    end

    def origin = "Febres, Portugal"
    end

    def destination = "Ourentã, Portugal" 
    end

    def last_updated = "7:30 AM"
    end
end