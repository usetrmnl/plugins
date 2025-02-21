module Plugins
    class GoldTracker < Base
      def locals
        {
          price: current_price,
          performance_7d: performance_7d,
          performance_90d: performance_90d,
          last_updated: last_updated
        }
      end
  
      private
  
      def current_price
        {
          value: 1776.83,
          currency: 'USD',
          formatted: '$1,776.83'
        }
      end
  
      def performance_7d
        {
          percentage: 2.5,
          value: 43.21,
          is_positive: true,
          formatted_percentage: '+2.5%',
          formatted_value: '$43.21'
        }
      end
  
      def performance_90d
        {
          percentage: 5.8,
          value: 97.45,
          is_positive: true,
          formatted_percentage: '+5.8%',
          formatted_value: '$97.45'
        }
      end
  
      def last_updated
        "10:30 AM"
      end

    #   eg https://api.metalpriceapi.com/v1/timeframe
# ?api_key=[API_KEY]
# &start_date=2021-04-22
# &end_date=2021-04-23
# &base=USD
# &currencies=EUR,XAU,XAG

# {
#   "success": true,
#   "base": "USD",
#   "start_date": "2021-04-22",
#   "end_date": "2021-04-23",
#   "rates": {
#       "2021-04-22": {
#         "EUR": 0.83233837,
#         "XAG": 0.03825732,
#         "XAU": 0.00056078,
#         "USDEUR": 1.20143446,
#         "USDXAG": 26.1387886,
#         "USDXAU": 1783.2305
#       },
#       "2021-04-23": {
#         "EUR": 0.82657397,
#         "XAG": 0.03846131,
#         "XAU": 0.0005628,
#         "USDEUR": 1.209813079,
#         "USDXAG": 26.00015444,
#         "USDXAU": 1776.830135
#       },
#   }

# And for live prices
# https://api.metalpriceapi.com/v1/latest?api_key=x&base=USD&currencies=EUR,XAU,XAG
#   "success": true,
#   "base": "USD",
#   "timestamp": 1740095999,
#   "rates": {
#     "EUR": 0.95935,
#     "USDEUR": 1.0423724397,
#     "USDXAG": 32.7383999975,
#     "USDXAU": 2937.0136856027,
#     "XAG": 0.0305451702,
#     "XAU": 0.0003404819
#   }
# }
    end
  end