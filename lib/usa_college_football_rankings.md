# College Football Top 10 Rankings Plugin on TRMNL

## Step 1: Create a New Private Plugin
Log in to your TRMNL dashboard.
On the left-hand menu, click on the 'Go to Plugins' button.
Find the 'Private Plugin' Plugin to create a Private Plugin.
Click 'Add new' to create a new Private Plugin.

## Step 2: Set up the Polling Strategy
Name your plugin (e.g., "College Football Top 10") then scroll down to the Strategy section.
Choose the Polling strategy from the Strategy dropdown menu.
In the Polling URL field, enter this URL:

```
https://site.api.espn.com/apis/site/v2/sports/football/college-football/rankings
```
Click Save. Once it is saved, the 'Edit Markup' button is not available.

## Step 3: Add the HTML Markup
Click the 'Edit Markup' button.

Copy and paste the following code into the Markup box. This code will display the Top 10 college football teams along with their rank, last week’s rank, and current record.

```
<div class="layout" style="text-align: center; font-size: 14px; font-family: Arial, sans-serif; margin-top: 15px;">
  <div class="columns">
    <div class="column">
      <div class="markdown">
        <span class="title" style="font-weight: bold; font-size: 18px; margin-bottom: 10px;">College Football Top 10 Rankings</span>
        <table style="width: 100%; margin: 15px auto; border-collapse: collapse; text-align: center;">
          <thead>
            <tr style="background-color: #f2f2f2;">
              <th style="padding: 6px; border: 1px solid #ddd;">Rank</th>
              <th style="padding: 6px; border: 1px solid #ddd;">Team</th>
              <th style="padding: 6px; border: 1px solid #ddd;">Last Week</th>
              <th style="padding: 6px; border: 1px solid #ddd;">Record</th>
            </tr>
          </thead>
          <tbody>
            {% assign counter = 1 %}
            {% for rank in rankings[0].ranks %}
            {% if counter <= 10 %}
            <tr>
              <td style="padding: 6px; border: 1px solid #ddd;">{{ counter }}</td> <!-- Using counter for the rank -->
              <td style="padding: 6px; border: 1px solid #ddd;">{{ rank.team.location }}</td> <!-- Only using location to avoid duplication -->
              <td style="padding: 6px; border: 1px solid #ddd;">{{ rank.previous }}</td>
              <td style="padding: 6px; border: 1px solid #ddd;">{{ rank.recordSummary }}</td>
            </tr>
            {% assign counter = counter | plus: 1 %}
            {% endif %}
            {% endfor %}
          </tbody>
        </table>
      </div>
    </div>
  </div>
</div>

```

## Step 4: Save and Activate the Plugin
Once you have entered the markup, click Save to store the plugin.
Navigate to the Playlists tab in your TRMNL dashboard.
Drag and drop your new College Football Top 10 plugin to the top of your playlist if not automatically added.

## Step 5: View the College Football Rankings on Your Device
Once refreshed, your TRMNL device will display the Top 10 College Football Rankings, showing the team’s current rank, last week’s rank, and win-loss record.

### Customizations (Optional)
Font Size: You can adjust the font size by changing the font-size values in the markup.
More Teams: If you want to display more than 10 teams, you can increase the limit in the code by replacing 10 with the number of teams you want in this line:

```
{% if counter <= 10 %}
```
Table Style: You can also modify the padding, borders, and colors of the table by changing the styles in the <th> and <td> elements.
